"""Exercise joined trace export streaming without Instruments or GPU activity.

Run: python3 -m unittest discover -s scripts -p 'test_performance_trace_streaming.py' -v
"""

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

import performance_trace_xml as trace


TARGET = "target-table"
GPU = "metal-gpu-intervals"
RAW = "metal-gpu-execution-points"
MAPPING = "metal-gpu-submission-to-command-buffer-id"


def gpu_row(pid=123, sid=17, *, start=100, duration=100, channel="Compute", command=19, encoder=23):
    process = "<process/>" if pid is None else f"<process><pid>{pid}</pid></process>"
    return (f"<start-time>{start}</start-time><duration>{duration}</duration><gpu-state>Active</gpu-state>"
            + process + f"<string>Test GPU</string><string>{channel}</string><uint64>{sid}</uint64>"
            f"<uint64>{command}</uint64><uint64>{encoder}</uint64>")


def raw_row(timestamp=100, sid=17, function=1, channel=9):
    return (f"<event-time>{timestamp}</event-time><uint64>{sid}</uint64>"
            f"<uint64>{channel}</uint64><uint64>{function}</uint64>")


def mapping_row(pid=123, sid=17, command=19, encoder=23, commit=29, submission_type=0):
    return (f"<pid>{pid}</pid><uint64>{sid}</uint64><uint64>{command}</uint64><uint64>{encoder}</uint64>"
            f"<uint64>{commit}</uint64><uint64>{submission_type}</uint64>")


def selection_document(gpu=(), raw=(), mappings=()):
    return document(
        node(GPU, dict(zip(
            ("start", "duration", "state", "process", "gpu", "channel-name", "gpu-submission-id",
             "cmdbuffer-id", "encoder-id"),
            ("start-time", "duration", "gpu-state", "process", "string", "string", "uint64", "uint64", "uint64"))), gpu),
        node(RAW, {"timestamp": "event-time", "gpu-submission-id": "uint64",
                   "channel-id": "uint64", "function": "uint64"}, raw),
        node(MAPPING, {"pid": "pid", "gpu-submission-id": "uint64",
                       "cmdbuffer-id": "uint64", "encoder-id": "uint64",
                       "commit-id": "uint64", "submission-type": "uint64"}, mappings))


def node(schema=None, columns=None, rows=(), *, number=None):
    xpath = "/trace-toc/run[@number='1']/data/table"
    if number is not None:
        xpath += f"[{number}]"
    header = ""
    if schema is not None:
        definitions = "".join(
            f"<col><mnemonic>{escape(name)}</mnemonic>"
            f"<engineering-type>{escape(kind)}</engineering-type></col>"
            for name, kind in (columns or {}).items())
        header = f"<schema name={quoteattr(schema)}>{definitions}</schema>"
    return (f"<node xpath={quoteattr(xpath)}>{header}"
            + "".join(f"<row>{row}</row>" for row in rows) + "</node>")


def document(*nodes):
    return "<?xml version='1.0'?><trace-query-result>" + "".join(nodes) + "</trace-query-result>"


class StreamingExportTests(unittest.TestCase):
    def setUp(self):
        trace.clear_cache()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "joined.xml"

    def write(self, source, metadata=None):
        self.path.write_text(source, encoding="utf-8")
        if metadata is not None:
            Path(str(self.path) + ".schema.json").write_text(
                json.dumps(metadata), encoding="utf-8")
        return self.path

    def read(self, source, schema=TARGET, metadata=None):
        return trace.read_table(self.write(source, metadata), schema)

    def assert_valid(self, result):
        self.assertEqual(result["invalid"], [])

    def test_forward_process_definition_nested_in_unrelated_node(self):
        source = document(
            node(TARGET, {"process": "process"}, ["<process ref='p1'/>"]),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label id='label' fmt='Unrelated label'>"
                "<process id='p1' fmt='FluxLLMApp (999)'><pid>123</pid>"
                "<device-session>session</device-session></process></formatted-label>"]))
        result = self.read(source)
        self.assert_valid(result)
        self.assertEqual(result["rows"][0]["process"], {
            "text": "", "fmt": "FluxLLMApp (999)", "pid": 123, "id": "p1", "tag": "process"})

    def test_forward_process_and_nested_pid_reference_chains(self):
        source = document(
            node(TARGET, {"process": "process"}, ["<process ref='p-alias'/>"]),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label><process id='p-alias' ref='p-middle'/>"
                "<process id='p-middle' ref='p-final'/></formatted-label>",
                "<formatted-label><process id='p-final' fmt='Worker (999)'>"
                "<pid ref='pid-alias'/></process><pid id='pid-alias' ref='pid-value'/>"
                "<pid id='pid-value'>456</pid></formatted-label>"]))
        result = self.read(source)
        self.assert_valid(result)
        self.assertEqual(result["rows"][0]["process"]["pid"], 456)
        self.assertEqual(result["rows"][0]["process"]["id"], "p-final")

    def test_repeated_schema_nodes_merge_in_export_order(self):
        columns = {"value": "uint64"}
        result = self.read(document(
            node(TARGET, columns, ["<uint64 ref='later'/>"]),
            node("unrelated", {"label": "string"}, ["<string>ignored</string>"]),
            node(TARGET, columns, ["<uint64 id='later'>42</uint64>", "<uint64>43</uint64>"])))
        self.assert_valid(result)
        self.assertEqual(result["columns"], columns)
        self.assertEqual([row["value"]["text"] for row in result["rows"]], ["42", "42", "43"])

    def test_conflicting_repeated_schema_fails_closed(self):
        result = self.read(document(
            node(TARGET, {"value": "uint64"}, ["<uint64>1</uint64>"]),
            node(TARGET, {"value": "string"}, ["<string>2</string>"])))
        self.assertTrue(result["invalid"])

    def test_sidecar_identifies_node_without_schema_header(self):
        columns = {"duration": "duration", "value": "uint64"}
        result = self.read(document(
            node("unrelated", {"value": "uint64"}, ["<uint64>100</uint64>"], number=2),
            node(rows=["<duration>16083</duration><uint64>7</uint64>"], number=7)),
            metadata={"tables": {"2": "unrelated", "7": TARGET}, "schemas": {TARGET: columns}})
        self.assert_valid(result)
        self.assertEqual(result["columns"], columns)
        self.assertEqual(result["rows"][0]["duration"]["text"], "16083")

    def test_time_sidecar_aliases_and_forward_referenced_timebase_components(self):
        columns = {"update-time": "sample-time", "mabs-epoch": "mach-absolute-time",
                   "mct-epoch": "mach-continuous-time", "timebase-info": "mach-timebase-info",
                   "trace-start-time": "time-since-epoch"}
        source = document(
            node(rows=["<sample-time>0</sample-time><mach-absolute-time>1000</mach-absolute-time>"
                       "<mach-continuous-time>2000</mach-continuous-time>"
                       "<mach-timebase-info ref='tb-alias'/><time-since-epoch>123456</time-since-epoch>"],
                 number=4),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label><mach-timebase-info id='tb-alias' ref='tb'/>"
                "<mach-timebase-info id='tb'><uint32 ref='numerator'/><uint32 ref='denom-alias'/>"
                "</mach-timebase-info><uint32 id='denom-alias' ref='denominator'/>"
                "<uint32 id='numerator'>125</uint32><uint32 id='denominator'>3</uint32>"
                "</formatted-label>"]))
        result = self.read(source, "time-info", {
            "tables": {"4": "time-info"}, "schemas": {"time-info": columns}})
        self.assert_valid(result)
        self.assertEqual(list(result["columns"]), ["timestamp", "mach-absolute-time",
                                                  "mach-continuous-time", "timebase", "time-since-epoch"])
        self.assertEqual(result["rows"][0]["timebase"]["components"], [125, 3])
        self.assertEqual(result["rows"][0]["mach-absolute-time"]["text"], "1000")

    def test_process_sidecar_aliases_preserve_numeric_identity(self):
        columns = {"time": "event-time", "pid": "pid", "unique-id": "uint64",
                   "process": "process", "process-name": "string"}
        source = document(node(rows=[
            "<event-time>0</event-time><pid id='pid'>123</pid><uint64>456789</uint64>"
            "<process fmt='Wrong display PID (999)'><pid ref='pid'/></process>"
            "<string>FluxLLMApp</string>"], number=9))
        result = self.read(source, "process-info", {
            "tables": {"9": "process-info"}, "schemas": {"process-info": columns}})
        self.assert_valid(result)
        self.assertEqual(list(result["columns"]), ["timestamp", "pid", "unique-id", "process", "name"])
        self.assertEqual(result["rows"][0]["process"]["pid"], 123)
        self.assertEqual(result["rows"][0]["name"]["text"], "FluxLLMApp")

    def test_builtin_time_shape_without_sidecar_resolves_forward_refs(self):
        source = document(
            node(rows=["<sample-time ref='timestamp'/><mach-absolute-time>100</mach-absolute-time>"
                       "<mach-continuous-time>200</mach-continuous-time><mach-timebase-info ref='tb'/>"
                       "<time-since-epoch>300</time-since-epoch>"]),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label><sample-time id='timestamp'>0</sample-time>"
                "<mach-timebase-info id='tb'><uint32>1</uint32><uint32>1</uint32>"
                "</mach-timebase-info></formatted-label>"]))
        result = self.read(source, "time-info")
        self.assert_valid(result)
        self.assertEqual(result["rows"][0]["timestamp"]["text"], "0")
        self.assertEqual(result["rows"][0]["timebase"]["components"], [1, 1])

    def test_builtin_process_shape_without_sidecar_resolves_forward_refs(self):
        source = document(
            node(rows=["<event-time>0</event-time><pid ref='pid'/><uint64>987</uint64>"
                       "<process ref='process'/><string>FluxLLMApp</string>"]),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label><process id='process'><pid id='pid'>123</pid>"
                "</process></formatted-label>"]))
        result = self.read(source, "process-info")
        self.assert_valid(result)
        self.assertEqual(result["rows"][0]["process"]["pid"], 123)

    def test_duplicate_ids_in_unrelated_nodes_invalidate_the_export(self):
        result = self.read(document(
            node(TARGET, {"value": "uint64"}, ["<uint64>1</uint64>"]),
            node("unrelated", {"label": "formatted-label"}, [
                "<formatted-label><string id='duplicate'>first</string></formatted-label>",
                "<formatted-label><string id='duplicate'>second</string></formatted-label>"])))
        self.assertTrue(result["invalid"])

    def test_unresolved_or_cyclic_refs_in_cells_and_nested_pids_are_invalid(self):
        fixtures = {
            "missing cell": "<process ref='missing'/>",
            "cyclic cell": "<process id='a' ref='b'/><process id='b' ref='a'/>",
            "missing pid": "<process id='p'><pid ref='missing'/></process>",
            "cyclic pid": "<process id='p'><pid id='a' ref='b'/><pid id='b' ref='a'/></process>",
        }
        for label, definition in fixtures.items():
            with self.subTest(case=label):
                source = document(
                    node(TARGET, {"process": "process"}, [
                        definition if label in ("missing cell", "missing pid", "cyclic pid")
                        else "<process ref='a'/>"]),
                    node("unrelated", {"label": "formatted-label"}, [
                        "<formatted-label>" + (definition if label == "cyclic cell" else "")
                        + "</formatted-label>"]))
                self.assertTrue(self.read(source)["invalid"])

    def test_unresolved_or_cyclic_timebase_component_refs_are_invalid(self):
        for components in ("<uint32 ref='missing'/><uint32>1</uint32>",
                           "<uint32 id='a' ref='b'/><uint32 id='b' ref='a'/>"):
            with self.subTest(components=components):
                source = document(node(rows=[
                    "<sample-time>0</sample-time><mach-absolute-time>100</mach-absolute-time>"
                    "<mach-continuous-time>200</mach-continuous-time><mach-timebase-info>"
                    + components + "</mach-timebase-info><time-since-epoch>300</time-since-epoch>"]))
                self.assertTrue(self.read(source, "time-info")["invalid"])

    def test_read_table_does_not_parse_a_whole_element_tree(self):
        self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64>42</uint64>"])))
        with mock.patch.object(trace.ET, "parse", side_effect=AssertionError("ET.parse retains the XML tree")):
            result = trace.read_table(self.path, TARGET)
        self.assert_valid(result)
        self.assertEqual(result["rows"][0]["value"]["text"], "42")

    def test_large_unrelated_rows_do_not_leave_elements_in_export_cache(self):
        unrelated = (
            f"<formatted-label id='label-{index}'><string id='name-{index}'>"
            f"Other process {index}</string><uint64>{index}</uint64></formatted-label>"
            for index in range(5000))
        self.write(document(
            node(TARGET, {"process": "process"}, ["<process ref='target-process'/>"]),
            node("unrelated", {"label": "formatted-label"}, unrelated),
            node("definitions", {"label": "formatted-label"}, [
                "<formatted-label><process id='target-process'><pid>123</pid></process></formatted-label>"])))
        parsed = []
        original_parse = trace._parse_export

        def capture_parsed_export(*args, **kwargs):
            value = original_parse(*args, **kwargs)
            parsed.append(value)
            return value

        with mock.patch.object(trace.ET, "parse", side_effect=AssertionError("ET.parse retains the XML tree")):
            with mock.patch.object(trace, "_parse_export", side_effect=capture_parsed_export):
                result = trace.read_table(self.path, TARGET)
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["process"]["pid"], 123)
        self.assertEqual(len(parsed), 1)
        self.assert_no_xml_elements(parsed[0])

    def assert_no_xml_elements(self, value, visited=None):
        visited = set() if visited is None else visited
        if id(value) in visited:
            return
        visited.add(id(value))
        self.assertNotIsInstance(value, ET.Element, "The export cache retains an XML Element")
        self.assertNotIsInstance(value, ET.ElementTree, "The export cache retains an XML tree")
        if isinstance(value, dict):
            children = list(value.keys()) + list(value.values())
        elif isinstance(value, (tuple, list, set, frozenset)):
            children = value
        else:
            children = list(vars(value).values()) if hasattr(value, "__dict__") else []
            for cls in type(value).__mro__:
                slots = cls.__dict__.get("__slots__", ())
                slots = (slots,) if isinstance(slots, str) else slots
                children.extend(getattr(value, slot) for slot in slots
                                if slot not in ("__dict__", "__weakref__") and hasattr(value, slot))
        for child in children:
            self.assert_no_xml_elements(child, visited)

    def test_mutating_returned_containers_does_not_corrupt_subsequent_reads(self):
        self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64 id='number'>42</uint64>"])))
        first = trace.read_table(self.path, TARGET)
        self.assert_valid(first)
        first["rows"].clear()
        first["columns"]["value"] = "corrupted"
        first["invalid"].append("caller change")
        second = trace.read_table(self.path, TARGET)
        self.assert_valid(second)
        self.assertEqual(second["columns"], {"value": "uint64"})
        self.assertEqual(second["rows"][0]["value"]["text"], "42")

    def test_multiple_schema_reads_parse_the_export_once(self):
        self.write(document(
            node(TARGET, {"value": "uint64"}, ["<uint64>42</uint64>"]),
            node("other-table", {"name": "string"}, ["<string>other</string>"])))
        with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
            first = trace.read_table(self.path, TARGET)
            second = trace.read_table(self.path, "other-table")
            repeated = trace.read_table(self.path, TARGET)
        for result in (first, second, repeated):
            self.assert_valid(result)
        self.assertEqual(parse.call_count, 1)
        self.assertEqual(first["rows"][0]["value"]["text"], "42")
        self.assertEqual(second["rows"][0]["name"]["text"], "other")

    def test_sidecar_changes_invalidate_cached_column_metadata(self):
        metadata = {"tables": {"7": TARGET}, "schemas": {TARGET: {"value": "uint64"}}}
        self.write(document(node(rows=["<uint64>42</uint64>"], number=7)), metadata)
        with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
            first = trace.read_table(self.path, TARGET)
            metadata["schemas"][TARGET]["value"] = "changed-engineering-type"
            Path(str(self.path) + ".schema.json").write_text(json.dumps(metadata), encoding="utf-8")
            second = trace.read_table(self.path, TARGET)
        self.assert_valid(first)
        self.assert_valid(second)
        self.assertEqual(first["columns"], {"value": "uint64"})
        self.assertEqual(second["columns"], {"value": "changed-engineering-type"})
        self.assertEqual(parse.call_count, 2)

    def test_export_changes_invalidate_cached_rows(self):
        self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64>42</uint64>"])))
        with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
            first = trace.read_table(self.path, TARGET)
            self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64>12345</uint64>"])))
            second = trace.read_table(self.path, TARGET)
        self.assert_valid(first)
        self.assert_valid(second)
        self.assertEqual(first["rows"][0]["value"]["text"], "42")
        self.assertEqual(second["rows"][0]["value"]["text"], "12345")
        self.assertEqual(parse.call_count, 2)

    def test_malformed_xml_is_reported_as_invalid(self):
        result = self.read("<trace-query-result><node><row>")
        self.assertTrue(result["invalid"])

    def test_schema_cell_count_mismatch_is_reported_as_invalid(self):
        for contents in ("", "<uint64>1</uint64><uint64>2</uint64>"):
            with self.subTest(contents=contents):
                result = self.read(document(node(TARGET, {"value": "uint64"}, [contents])))
                self.assertTrue(result["invalid"])
                self.assertEqual(result["rows"], [])

    def test_expired_deadline_propagates_without_starting_parse(self):
        self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64>42</uint64>"])))
        with mock.patch.object(trace.time, "monotonic", return_value=10):
            with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
                with self.assertRaises(TimeoutError):
                    trace.read_table(self.path, TARGET, deadline=10)
        self.assertEqual(parse.call_count, 0)

    def test_mid_parse_deadline_propagates_and_does_not_cache_partial_results(self):
        self.write(document(node(TARGET, {"value": "uint64"},
                                 (f"<uint64>{value}</uint64>" for value in range(2050)))))
        with mock.patch.object(trace.time, "monotonic", side_effect=[0, 0, 0, 2]):
            with self.assertRaises(TimeoutError):
                trace.read_table(self.path, TARGET, deadline=1)
        self.assertEqual(trace.cache_info().currsize, 0)
        result = trace.read_table(self.path, TARGET)
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 2050)

    def test_cached_result_still_obeys_an_expired_deadline(self):
        self.write(document(node(TARGET, {"value": "uint64"}, ["<uint64>42</uint64>"])))
        self.assert_valid(trace.read_table(self.path, TARGET))
        with mock.patch.object(trace.time, "monotonic", side_effect=[0, 2]):
            with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
                with self.assertRaises(TimeoutError):
                    trace.read_table(self.path, TARGET, deadline=1)
        self.assertEqual(parse.call_count, 0)
        self.assert_valid(trace.read_table(self.path, TARGET))

    def test_selection_keeps_owned_and_anonymous_gpu_but_drops_proven_unrelated_pairs(self):
        self.write(selection_document(
            gpu=[gpu_row(123, 17), gpu_row(None, 18), gpu_row(999, 19, command=111, encoder=222)],
            raw=[raw_row(timestamp, sid, function)
                 for sid in (17, 18, 19) for timestamp, function in ((100, 1), (200, 2))],
            mappings=[mapping_row(123, 17), mapping_row(999, 19, command=111, encoder=222)]))
        result = trace.read_table(self.path, GPU, process_ids={123})
        self.assert_valid(result)
        self.assertEqual([row["process"]["pid"] for row in result["rows"]], [123, None])
        self.assertEqual({key: result["selection"][key] for key in (
            "input_row_count", "retained_row_count", "excluded_known_unrelated_rows", "process_ids")},
            {"input_row_count": 3, "retained_row_count": 2,
             "excluded_known_unrelated_rows": 1, "process_ids": [123]})
        points = trace.read_table(self.path, RAW, process_ids={123})
        self.assertEqual([row["gpu-submission-id"]["text"] for row in points["rows"]], ["17", "17", "18", "18"])

    def test_selection_keeps_explicit_unrelated_gpu_with_conflicting_owned_metadata(self):
        self.write(selection_document(
            gpu=[gpu_row(999)], raw=[raw_row(100, function=1), raw_row(200, function=2)],
            mappings=[mapping_row(123)]))
        for schema, count in ((GPU, 1), (RAW, 2), (MAPPING, 1)):
            with self.subTest(schema=schema):
                result = trace.read_table(self.path, schema, process_ids={123})
                self.assert_valid(result)
                self.assertEqual(len(result["rows"]), count)
                self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 0)

    def test_selection_retains_raw_sid_alias_despite_foreign_modeled_command_identity(self):
        self.write(selection_document(
            gpu=[gpu_row(999, command=19)], raw=[raw_row(100, function=1), raw_row(200, function=2)],
            mappings=[mapping_row(123, command=99), mapping_row(999, command=19)]))
        result = trace.read_table(self.path, GPU, process_ids={123})
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["process"]["pid"], 999)
        self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 2)
        metadata = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assertEqual([row["pid"]["text"] for row in metadata["rows"]], ["123", "999"])

    def test_selection_retains_unknown_or_unmapped_sid_even_with_a_foreign_modeled_pid(self):
        for mappings in ([], [mapping_row(0, command=99), mapping_row(999, command=19)]):
            with self.subTest(mappings=mappings):
                trace.clear_cache()
                self.write(selection_document(gpu=[gpu_row(999)],
                    raw=[raw_row(100, function=1), raw_row(200, function=2)], mappings=mappings))
                self.assertEqual(len(trace.read_table(self.path, GPU, process_ids={123})["rows"]), 1)
                self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 2)
                self.assertEqual(len(trace.read_table(self.path, MAPPING, process_ids={123})["rows"]), len(mappings))

    def test_selection_keeps_raw_pairs_without_modeled_gpu_and_their_metadata(self):
        self.write(selection_document(
            raw=[raw_row(100, function=1), raw_row(200, function=2)], mappings=[mapping_row(999)]))
        points = trace.read_table(self.path, RAW, process_ids={123})
        self.assert_valid(points)
        self.assertEqual(len(points["rows"]), 2)
        self.assertEqual(points["selection"]["excluded_known_unrelated_rows"], 0)
        self.assertEqual(len(trace.read_table(self.path, MAPPING, process_ids={123})["rows"]), 1)

    def test_selection_keeps_unpaired_and_malformed_raw_rows(self):
        rows = [raw_row(100, function=1), raw_row("not-a-timestamp", sid=18),
                "<event-time>300</event-time><uint64>19</uint64><uint64>9</uint64>"]
        self.write(selection_document(gpu=[gpu_row(999)], raw=rows))
        points = trace.read_table(self.path, RAW, process_ids={123})
        self.assertTrue(points["invalid"])
        self.assertEqual(points["selection"]["retained_row_count"], 3)
        self.assertEqual(points["selection"]["excluded_known_unrelated_rows"], 0)
        self.assertEqual(len(points["rows"]), 2)
        self.assertEqual(points["rows"][1]["timestamp"]["text"], "not-a-timestamp")
        self.assertEqual(len(trace.read_table(self.path, GPU, process_ids={123})["rows"]), 1)

    def test_selection_keeps_unrelated_gpu_when_raw_channel_count_differs(self):
        self.write(selection_document(
            gpu=[gpu_row(999)], raw=[raw_row(timestamp, function=function, channel=channel)
                                    for channel in (9, 10) for timestamp, function in ((100, 1), (200, 2))]))
        self.assertEqual(len(trace.read_table(self.path, GPU, process_ids={123})["rows"]), 1)
        self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 4)

    def test_selection_keeps_unrelated_gpu_when_pair_times_do_not_match(self):
        self.write(selection_document(gpu=[gpu_row(999)],
                                      raw=[raw_row(100, function=1), raw_row(201, function=2)]))
        self.assertEqual(len(trace.read_table(self.path, GPU, process_ids={123})["rows"]), 1)
        self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 2)

    def test_selection_keeps_metadata_for_retained_gpu_and_owned_rows(self):
        self.write(selection_document(
            gpu=[gpu_row(None, 17)],
            mappings=[mapping_row(999, 17), mapping_row(123, 18), mapping_row(999, 19, command=99)]))
        metadata = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assert_valid(metadata)
        self.assertEqual([row["gpu-submission-id"]["text"] for row in metadata["rows"]], ["17", "18"])
        self.assertEqual(metadata["selection"]["excluded_known_unrelated_rows"], 1)

    def test_selection_cache_is_scoped_to_the_requested_process_ids(self):
        self.write(selection_document(
            gpu=[gpu_row(123, 17), gpu_row(999, 18, command=111, encoder=222)],
            raw=[raw_row(timestamp, sid, function)
                 for sid in (17, 18) for timestamp, function in ((100, 1), (200, 2))],
            mappings=[mapping_row(123, 17), mapping_row(999, 18, command=111, encoder=222)]))
        with mock.patch.object(trace, "_parse_export", wraps=trace._parse_export) as parse:
            first = trace.read_table(self.path, GPU, process_ids={123})
            repeated = trace.read_table(self.path, GPU, process_ids={123})
            second = trace.read_table(self.path, GPU, process_ids={999})
        for result in (first, repeated, second):
            self.assert_valid(result)
        self.assertEqual(parse.call_count, 2)
        self.assertEqual([row["process"]["pid"] for row in first["rows"]], [123])
        self.assertEqual([row["process"]["pid"] for row in second["rows"]], [999])

    def test_selection_keeps_wrong_tag_process_cells_unattributed(self):
        wrong_tag = gpu_row(999).replace("<process><pid>999</pid></process>",
                                         "<mach-timebase-info><pid>999</pid></mach-timebase-info>")
        self.write(selection_document(gpu=[wrong_tag],
                                      raw=[raw_row(100, function=1), raw_row(200, function=2)]))
        result = trace.read_table(self.path, GPU, process_ids={123})
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 1)
        self.assertIsNone(result["rows"][0]["process"]["pid"])
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 0)
        self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 2)

    def test_selection_keeps_invalid_nested_pid_in_an_unrelated_column(self):
        malformed = gpu_row(999).replace("<duration>100</duration>",
                                        "<process>100<pid>bad</pid></process>")
        self.write(selection_document(gpu=[malformed],
                                      raw=[raw_row(100, function=1), raw_row(200, function=2)]))
        result = trace.read_table(self.path, GPU, process_ids={123})
        self.assertTrue(result["invalid"])
        self.assertEqual(result["selection"]["retained_row_count"], 1)
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 0)
        self.assertEqual(len(trace.read_table(self.path, RAW, process_ids={123})["rows"]), 2)

    def test_selection_keeps_process_info_with_invalid_timestamp(self):
        columns = {"timestamp": "event-time", "pid": "pid", "unique-id": "uint64",
                   "process": "process", "name": "string"}
        self.write(document(node("process-info", columns, [
            "<event-time>bad</event-time><pid>999</pid><uint64>12345</uint64>"
            "<process id='process-999'><pid>999</pid></process><string>Other</string>"])))
        result = trace.read_table(self.path, "process-info", process_ids={123})
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["timestamp"]["text"], "bad")
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 0)

    def test_selection_keeps_submission_metadata_with_conflicting_process_pid(self):
        columns = {"pid": "pid", "gpu-submission-id": "uint64", "cmdbuffer-id": "uint64",
                   "encoder-id": "uint64", "commit-id": "uint64", "submission-type": "uint64",
                   "process": "process"}
        self.write(document(node(MAPPING, columns, [
            mapping_row(456) + "<process><pid>123</pid></process>",
            mapping_row(456, sid=18) + "<process><pid>456</pid></process>"])))
        result = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assert_valid(result)
        self.assertEqual(len(result["rows"]), 1)
        self.assertEqual(result["rows"][0]["pid"]["text"], "456")
        self.assertEqual(result["rows"][0]["process"]["pid"], 123)
        self.assertEqual(result["selection"]["input_row_count"], 2)
        self.assertEqual(result["selection"]["retained_row_count"], 1)
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 1)

    def test_selection_preserves_foreign_command_collision_with_different_submission(self):
        self.write(selection_document(mappings=[
            mapping_row(123, sid=17, command=19),
            mapping_row(999, sid=88, command=19),
            mapping_row(999, sid=89, command=99)]))
        result = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assert_valid(result)
        self.assertEqual([row["gpu-submission-id"]["text"] for row in result["rows"]], ["17", "88"])
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 1)

    def test_selection_preserves_foreign_mapping_for_owned_frame_without_owned_mapping(self):
        frame_schema = "metal-command-buffer-frame-assignment"
        completion_schema = "metal-command-buffer-completed"
        frames = node(frame_schema, {"pid": "pid", "cmdbuffer-id": "uint64"}, [
            "<pid>123</pid><uint64>19</uint64>", "<pid>999</pid><uint64>99</uint64>",
            "<pid>bad</pid><uint64>101</uint64>"])
        completions = node(completion_schema, {"cmdbuffer-id": "uint64"}, [
            "<uint64>19</uint64>", "<uint64>99</uint64>", "<uint64>bad</uint64>"])
        source = selection_document(mappings=[mapping_row(999, command=19), mapping_row(999, command=99)])
        self.write(source.replace("</trace-query-result>", frames + completions + "</trace-query-result>"))
        result = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assert_valid(result)
        self.assertEqual([row["cmdbuffer-id"]["text"] for row in result["rows"]], ["19"])
        for schema in (frame_schema, completion_schema):
            result = trace.read_table(self.path, schema, process_ids={123})
            self.assertEqual(len(result["rows"]), 3)
            self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 0)

    def test_selection_preserves_malformed_terminal_mapping_fields(self):
        self.write(selection_document(mappings=[
            mapping_row(999, command=99, commit="bad"),
            mapping_row(999, command=100, submission_type="bad"),
            mapping_row(999, command=101)]))
        result = trace.read_table(self.path, MAPPING, process_ids={123})
        self.assertEqual([row["cmdbuffer-id"]["text"] for row in result["rows"]], ["99", "100"])
        self.assertEqual(result["selection"]["excluded_known_unrelated_rows"], 1)



if __name__ == "__main__":
    unittest.main()
