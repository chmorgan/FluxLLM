"""Read joined Instruments exports once without retaining an XML element tree.

Rows and resolved cells are compact shared cache values. Callers should treat
row/cell dictionaries as read-only; each call receives its own result, column,
row-list, and diagnostic-list containers. The cache owns at most one export.
"""

from dataclasses import dataclass, field
from collections import defaultdict
from contextvars import ContextVar
from functools import lru_cache
import json
from pathlib import Path
import re
import time
import xml.etree.ElementTree as ET


class ExportError(ValueError):
    pass


_READ_DEADLINE = ContextVar("performance_trace_xml_deadline", default=None)


def _check_deadline(deadline):
    if deadline is not None and time.monotonic() >= deadline:
        raise TimeoutError("Performance deadline expired while reading Instruments XML")


@dataclass(slots=True, eq=False)
class _Value:
    tag: str
    text: str
    fmt: str
    identifier: str | None
    children: tuple = ()


@dataclass(slots=True)
class _Frame:
    element: object
    children: list = field(default_factory=list)


@dataclass(slots=True)
class _Table:
    xpath: str
    schema: str | None = None
    columns: dict | None = None
    rows: list = field(default_factory=list)


_BUILTINS = {
    "time-info": (
        ("sample-time", "mach-absolute-time", "mach-continuous-time", "mach-timebase-info", "time-since-epoch"),
        ("timestamp", "mach-absolute-time", "mach-continuous-time", "timebase", "time-since-epoch"),
    ),
    "process-info": (
        ("event-time", "pid", "uint64", "process", "string"),
        ("timestamp", "pid", "unique-id", "process", "name"),
    ),
}
_ALIASES = {
    "time-info": {"update-time": "timestamp", "mabs-epoch": "mach-absolute-time",
                  "mct-epoch": "mach-continuous-time", "timebase-info": "timebase",
                  "trace-start-time": "time-since-epoch"},
    "process-info": {"time": "timestamp", "process-name": "name"},
}


def _integer(text):
    if not isinstance(text, str) or not re.fullmatch(r"[0-9]+", text.strip()):
        raise ExportError(f"Expected a nonnegative raw integer, got {text!r}")
    return int(text)


def _signature(path):
    try:
        value = path.stat()
    except FileNotFoundError:
        return None
    return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)


def _metadata(path):
    if not path.is_file():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ExportError("Export schema metadata is not an object")
    for key in ("tables", "schemas"):
        if not isinstance(value.get(key, {}), dict):
            raise ExportError(f"Export schema metadata {key} is not an object")
    if any(not isinstance(name, str) for name in value.get("tables", {}).values()):
        raise ExportError("Export schema metadata has an invalid table identity")
    for name, columns in value.get("schemas", {}).items():
        if not isinstance(name, str) or not isinstance(columns, dict):
            raise ExportError("Export schema metadata has invalid column definitions")
    return value


def _parse_export(path, metadata_path, *, deadline=None, process_ids=None):
    """One streaming pass; references are resolved after all definitions exist."""
    _check_deadline(deadline)
    metadata = _metadata(metadata_path)
    identifiers = {}
    tables = []
    node_tables = {}
    stack = []
    for event_index, (event, element) in enumerate(ET.iterparse(path, events=("start", "end"))):
        if event_index % 2048 == 0:
            _check_deadline(deadline)
        if event == "start":
            stack.append(_Frame(element))
            if element.tag == "node":
                table = _Table(element.get("xpath", ""))
                tables.append(table)
                node_tables[id(element)] = table
            continue
        frame = stack.pop()
        parent = stack[-1].element if stack else None
        value = (element.get("ref") or _Value(
            element.tag, element.text or "", element.get("fmt", ""),
            element.get("id"), tuple(frame.children)))
        identifier = element.get("id")
        if identifier:
            if identifier in identifiers:
                raise ExportError(f"Duplicate XML id {identifier}")
            identifiers[identifier] = value
        if stack and parent.tag in ("row", "process", "mach-timebase-info"):
            stack[-1].children.append(value)
        if parent is not None and parent.tag == "node":
            table = node_tables[id(parent)]
            if element.tag == "schema":
                if table.columns is not None:
                    raise ExportError("An export table has multiple schema headers")
                table.schema = element.get("name")
                table.columns = {
                    column.findtext("mnemonic"): column.findtext("engineering-type")
                    for column in element.findall("col")
                }
            elif element.tag == "row":
                table.rows.append(tuple(frame.children))
            # Remove completed siblings: clear() alone retains one empty
            # Element per row in the parent, which still grows with the export.
            parent.remove(element)
            element.clear()
        elif element.tag == "node":
            node_tables.pop(id(element), None)
            if parent is not None:
                parent.remove(element)
            element.clear()

    resolved = {}
    cells = {}

    def resolve(value):
        if not isinstance(value, str):
            return value
        seen = set()
        while isinstance(value, str):
            if seen and len(seen) % 1024 == 0:
                _check_deadline(deadline)
            if value in resolved:
                value = resolved[value]
                break
            if value in seen or value not in identifiers:
                raise ExportError(f"Unresolved or cyclic XML reference {value}")
            seen.add(value)
            value = identifiers[value]
        for identifier in seen:
            resolved[identifier] = value
        return value

    def cell(value):
        value = resolve(value)
        cached = cells.get(value)
        if cached is not None:
            return cached
        pid = None
        if value.tag == "process":
            pids = [child for item in value.children if (child := resolve(item)).tag == "pid"]
            if len(pids) == 1:
                pid = _integer(pids[0].text)
        result = {"text": value.text, "fmt": value.fmt, "pid": pid,
                  "id": value.identifier, "tag": value.tag}
        cells[value] = result
        return result

    results = {}
    builtin_errors = []
    prepared = []
    for table in tables:
        _check_deadline(deadline)
        name, columns = table.schema, table.columns
        if columns is None:
            match = re.search(r"/table\[(\d+)\]$", table.xpath)
            name = metadata.get("tables", {}).get(match.group(1)) if match else None
            columns = metadata.get("schemas", {}).get(name)
            if columns is None and table.rows:
                try:
                    tags = tuple(resolve(value).tag for value in table.rows[0])
                except ExportError as error:
                    builtin_errors.append(str(error))
                    continue
                for candidate, (expected, names) in _BUILTINS.items():
                    if tags == expected:
                        name, columns = candidate, dict.fromkeys(names, "builtin")
                        break
        if name is None or columns is None:
            continue
        result = results.setdefault(name, {"columns": {}, "rows": [], "invalid": []})
        aliases = _ALIASES.get(name, {})
        columns = {aliases.get(key, key): kind for key, kind in columns.items()}
        if not columns or None in columns:
            result["invalid"].append(f"Missing {name} column definitions")
            continue
        if result["columns"] and result["columns"] != columns:
            result["invalid"].append(f"Inconsistent {name} schemas")
            continue
        result["columns"] = columns
        prepared.append((name, columns, table.rows))
    exclusions = _select_rows(prepared, resolve, process_ids, deadline) if process_ids is not None else set()
    for name, columns, rows in prepared:
        result = results[name]
        selection = result.setdefault("selection", {
            "input_row_count": 0, "retained_row_count": 0,
            "excluded_known_unrelated_rows": 0,
            "process_ids": sorted(process_ids) if process_ids is not None else None,
            "backend": "xml.etree.ElementTree", "backend_version": ET.VERSION})
        selection["input_row_count"] += len(rows)
        for row_index, row in enumerate(rows):
            if row_index % 1024 == 0:
                _check_deadline(deadline)
            if id(row) in exclusions:
                selection["excluded_known_unrelated_rows"] += 1
                continue
            selection["retained_row_count"] += 1
            if len(row) != len(columns):
                result["invalid"].append(f"{name} row has {len(row)} cells; expected {len(columns)}")
                continue
            try:
                values = {key: cell(value) for key, value in zip(columns, row)}
                if name == "time-info":
                    timebase = resolve(row[3])
                    # Do not mutate a cell shared with another schema's view.
                    values["timebase"] = dict(values["timebase"], components=[
                        _integer(resolve(value).text) for value in timebase.children])
                result["rows"].append(values)
            except (ExportError, KeyError, IndexError) as error:
                result["invalid"].append(str(error))
        rows.clear()
    for name in _BUILTINS:
        if builtin_errors:
            result = results.setdefault(name, {"columns": {}, "rows": [], "invalid": []})
            result["invalid"].extend(builtin_errors)
    _check_deadline(deadline)
    return results


def _select_rows(tables, resolve, process_ids, deadline):
    """Exclude only rows proven unrelated by exact modeled execution pairs.

    Submission IDs are not globally unique. Raw records, unknown ownership,
    contradictory metadata, incomplete pairs and malformed values survive for
    the main evaluator to reject or conservatively bound.
    """
    owned = frozenset(process_ids)
    excluded, metadata_rows, gpu_rows, raw_rows = set(), [], [], []
    composite_owners = defaultdict(set)
    modeled_channels, modeled_rows = defaultdict(set), defaultdict(list)
    protected_keys, protected_sids = set(), set()
    all_rows = defaultdict(list)
    for name, columns, rows in tables:
        all_rows[name].append((tuple(columns), rows))

    def decoded(name):
        for columns, rows in all_rows[name]:
            for index, row in enumerate(rows):
                if index % 1024 == 0:
                    _check_deadline(deadline)
                try:
                    if len(columns) != len(row):
                        continue
                    # Resolve every cell before exclusion, including cells the
                    # ownership projection does not otherwise need.
                    values = tuple(resolve(value) for value in row)
                    for value in values:
                        if value.tag == "process":
                            pid_of(value)
                    yield row, dict(zip(columns, values))
                except ExportError:
                    continue

    def number(values, key):
        return _integer(values[key].text)

    def pid_of(value):
        if value.tag != "process":
            return None
        children = [resolve(item) for item in value.children]
        pids = [item for item in children if item.tag == "pid"]
        return _integer(pids[0].text) if len(pids) == 1 else None

    # Completion fences join command/commit identities across all processes.
    # Keep foreign metadata for any owned command, even with a different SID.
    owned_commands = set()
    for _, values in decoded("metal-command-buffer-frame-assignment"):
        try:
            if number(values, "pid") in owned:
                owned_commands.add(number(values, "cmdbuffer-id"))
        except (ExportError, KeyError):
            pass
    for row, values in decoded("metal-gpu-submission-to-command-buffer-id"):
        try:
            pid = number(values, "pid")
            process_pid = pid_of(values["process"]) if "process" in values else None
            if process_pid is not None and process_pid != pid:
                continue
            command = number(values, "cmdbuffer-id")
            if pid in owned:
                owned_commands.add(command)
            sid = number(values, "gpu-submission-id")
            identity = (sid, command, number(values, "encoder-id"))
            composite_owners[identity].add(pid)
            # The terminal proof rejects malformed command/commit mappings.
            # Such evidence must remain visible even when its PID is foreign.
            number(values, "commit-id")
            number(values, "submission-type")
            metadata_rows.append((row, sid, pid, command))
        except (ExportError, KeyError):
            pass
    for row, values in decoded("metal-gpu-intervals"):
        try:
            if values["state"].text != "Active":
                continue
            start, duration = number(values, "start"), number(values, "duration")
            if duration <= 0 or not values["gpu"].text or not values["channel-name"].text:
                continue
            sid = number(values, "gpu-submission-id")
            identity = (sid, number(values, "cmdbuffer-id"), number(values, "encoder-id"))
            pid = pid_of(values["process"])
            key = (sid, start, start + duration)
            modeled_channels[key].add((values["gpu"].text, values["channel-name"].text))
            modeled_rows[key].append(row)
            gpu_rows.append((row, sid, key))
            owners = composite_owners[identity]
            if not pid or pid in owned or (owners and pid not in owners) or owners.intersection(owned):
                protected_keys.add(key)
        except (ExportError, KeyError):
            pass
    open_points, point_rows, pair_channels = {}, defaultdict(list), defaultdict(set)
    seen, paired_points = set(), {}
    for row, values in decoded("metal-gpu-execution-points"):
        try:
            timestamp, sid = number(values, "timestamp"), number(values, "gpu-submission-id")
            channel, function = number(values, "channel-id"), number(values, "function")
            point = (channel, sid, timestamp, function)
            point_rows[point].append(row)
            raw_rows.append((row, sid, point))
            if point in seen:
                continue
            seen.add(point)
            if function == 1:
                if (channel, sid) in open_points:
                    protected_sids.add(sid)
                open_points[(channel, sid)] = point
            elif function == 2 and (channel, sid) in open_points:
                first = open_points.pop((channel, sid))
                if timestamp <= first[2]:
                    protected_sids.add(sid)
                    continue
                key = (sid, first[2], timestamp)
                pair_channels[key].add(channel)
                paired_points[first] = paired_points[point] = key
            else:
                protected_sids.add(sid)
        except (ExportError, KeyError):
            pass
    protected_sids.update(sid for _, sid in open_points)
    removable = {key for key, channels in modeled_channels.items()
                 if key not in protected_keys and key[0] not in protected_sids
                 and len(channels) == len(pair_channels.get(key, ())) }
    for key in removable:
        excluded.update(id(row) for row in modeled_rows[key])
    for point, key in paired_points.items():
        if key in removable:
            excluded.update(id(row) for row in point_rows[point])
    retained_sids = {sid for row, sid, _ in gpu_rows + raw_rows if id(row) not in excluded}
    for row, sid, pid, command in metadata_rows:
        if pid not in owned and sid not in retained_sids and command not in owned_commands:
            excluded.add(id(row))
    for row, values in decoded("process-info"):
        try:
            pid = number(values, "pid")
            number(values, "timestamp")
            if (pid not in owned and values["unique-id"].text and values["process"].identifier
                    and pid_of(values["process"]) == pid):
                excluded.add(id(row))
        except (ExportError, KeyError):
            pass
    _check_deadline(deadline)
    return excluded


@lru_cache(maxsize=1)
def _cached_export(path, xml_signature, metadata_signature, process_ids):
    result = _parse_export(Path(path), Path(path + ".schema.json"), deadline=_READ_DEADLINE.get(), process_ids=process_ids)
    if _signature(Path(path)) != xml_signature or _signature(Path(path + ".schema.json")) != metadata_signature:
        raise ExportError("Export or schema metadata changed while it was being read")
    return result


def clear_cache():
    _cached_export.cache_clear()


def cache_info():
    return _cached_export.cache_info()


def read_table(path, schema, *, deadline=None, process_ids=None):
    result = {"schema": schema, "columns": {}, "rows": [], "invalid": []}
    token = _READ_DEADLINE.set(deadline)
    try:
        _check_deadline(deadline)
        path = Path(path).resolve()
        signature = _signature(path)
        if signature is None:
            raise FileNotFoundError(f"Export does not exist: {path}")
        loaded = _cached_export(str(path), signature, _signature(Path(str(path) + ".schema.json")),
                                None if process_ids is None else frozenset(process_ids))
        table = loaded.get(schema)
        if table is None:
            result["invalid"].append(f"Export contains no {schema} table")
        else:
            result.update(columns=dict(table["columns"]), rows=list(table["rows"]), invalid=list(table["invalid"]))
            if "selection" in table:
                result["selection"] = dict(table["selection"])
        _check_deadline(deadline)
    except TimeoutError:
        raise
    except (OSError, ET.ParseError, ValueError) as error:
        result["invalid"].append(str(error))
    finally:
        _READ_DEADLINE.reset(token)
    return result
