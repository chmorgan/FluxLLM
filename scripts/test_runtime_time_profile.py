"""Offline XML/clock attribution and mocked exporter checks; no native launch."""
from contextlib import nullcontext
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

import runtime_time_profile as profile

PID = 1234
START = "2026-10-02T10:00:00.000-04:00"


def toc_xml():
    return f'''<trace-toc><run number="1"><info><target><process pid="{PID}"/></target>
      <summary><start-date>{START}</start-date><end-date>2026-10-02T10:00:10.000-04:00</end-date>
      <duration>10</duration><template-name>Time Profiler</template-name></summary></info>
      <data><table schema="time-profile"/></data></run></trace-toc>'''


def table_xml():
    root = ET.Element("trace-query-result")
    node = ET.SubElement(root, "node")
    schema = ET.SubElement(node, "schema", name="time-profile")
    for mnemonic, kind in profile.SCHEMA_COLUMNS.items():
        col = ET.SubElement(schema, "col")
        ET.SubElement(col, "mnemonic").text = mnemonic
        ET.SubElement(col, "engineering-type").text = kind
    for index, timestamp in enumerate((1, 2, 3, 9)):
        row = ET.SubElement(node, "row")
        ET.SubElement(row, "sample-time").text = str(timestamp * 1_000_000_000)
        if index == 0:
            process = ET.SubElement(row, "process", id="p")
            ET.SubElement(process, "pid").text = str(PID)
            thread = ET.SubElement(row, "thread", id="t", fmt="Main Thread")
            ET.SubElement(thread, "tid").text = "7"
            ET.SubElement(thread, "process", ref="p")
            ET.SubElement(row, "thread-state", id="state").text = "Running"
            ET.SubElement(row, "weight", id="w", fmt="1.00 ms").text = "1000000"
            backtrace = ET.SubElement(ET.SubElement(row, "tagged-backtrace", id="stack"), "backtrace")
            ET.SubElement(backtrace, "frame", id="f", name="MetricsStore.sample()")
            ET.SubElement(backtrace, "frame", ref="f")
            ET.SubElement(backtrace, "frame", name="parent")
        else:
            for tag, reference in (("process", "p"), ("thread", "t"), ("thread-state", "state"), ("weight", "w"), ("tagged-backtrace", "stack")):
                ET.SubElement(row, tag, ref=reference)
    return ET.tostring(root, encoding="unicode")


def anchor():
    def bridge(mono):
        return {"mach_ticks": (mono + 10) * 1_000_000_000, "numer": 1, "denom": 1,
                "monotonic_seconds": mono, "uncertainty_seconds": 0.0000001,
                "absolute_minus_monotonic_seconds": 10}
    return {"monotonic_before_ns": 100_000_000_000, "monotonic_after_ns": 100_000_000_000,
            "wall_time_ns": profile.epoch_ns(START), "mach_clock_start": bridge(99), "mach_clock_end": bridge(111)}


def kernel_samples():
    result = []
    for index in range(21):
        mono = 100 + index / 2
        result.append({"process_id": PID, "birth_time_us": 123456,
                       "monotonic_seconds": 500 + index / 2, "cpu_seconds": index * .005,
                       "mach_absolute_ticks": int((mono + 10) * 1e9), "mach_timebase_numer": 1,
                       "mach_timebase_denom": 1, "mach_absolute_seconds": mono + 10,
                       "clock_read_uncertainty_seconds": .0000001})
    return result


class AttributionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.toc, self.table = self.root / "toc.xml", self.root / "time-profile.xml"
        self.toc.write_text(toc_xml())
        self.table.write_text(table_xml())
        self.windows = {"arrival": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}}
        self.anchor, self.samples = anchor(), kernel_samples()

    def analyze(self):
        return profile.analyze_exports(self.toc, self.table, PID, self.windows, self.anchor, self.samples)

    def mutate_table(self, callback):
        tree = ET.parse(self.table)
        callback(tree.getroot())
        tree.write(self.table, encoding="utf-8")

    def test_recursion_counts_once_and_kernel_uses_mach_clock(self):
        result = self.analyze()
        self.assertEqual(result["status"], "profiled_phase_attribution_available")
        self.assertFalse(result["regression_passed"])
        phase = result["phases"][0]
        self.assertEqual(phase["total"]["sample_count"], 2)
        self.assertEqual(phase["total"]["weight_ns"], 2_000_000)
        self.assertEqual(phase["top_inclusive_symbols"][0]["weight_ns"], 2_000_000)
        self.assertEqual(phase["top_leaf_symbols"][0]["sample_count"], 2)
        self.assertAlmostEqual(phase["kernel_cpu_same_window"]["cpu_seconds"], .02)
        self.assertAlmostEqual(phase["kernel_cpu_same_window"]["rolling_1s_percent"], 1)
        self.assertFalse(phase["kernel_cpu_same_window"]["acceptance_eligible"])
        self.assertEqual(phase["window_mach_absolute_seconds"], [112, 114])
        self.assertAlmostEqual(phase["total"]["cpu_percent_one_core"], .1)

    def test_wrong_toc_pid_rejected(self):
        self.toc.write_text(toc_xml().replace('pid="1234"', 'pid="999"'))
        with self.assertRaisesRegex(ValueError, "owned PID"):
            self.analyze()

    def test_multiple_runs_rejected(self):
        self.toc.write_text(toc_xml().replace("</trace-toc>", '<run number="2"/></trace-toc>'))
        with self.assertRaisesRegex(ValueError, "exactly run 1"):
            self.analyze()

    def test_wrong_template_and_duration_rejected(self):
        for original, replacement, message in (("Time Profiler", "Metal System Trace", "template"), ("<duration>10", "<duration>nan", "duration"), ("<duration>10", "<duration>9", "disagrees")):
            with self.subTest(replacement=replacement):
                self.toc.write_text(toc_xml().replace(original, replacement))
                with self.assertRaisesRegex(ValueError, message):
                    self.analyze()

    def test_duplicate_running_sample_rejected(self):
        self.table.write_text(table_xml().replace("3000000000", "2000000000"))
        with self.assertRaisesRegex(ValueError, "Duplicate Running"):
            self.analyze()

    def test_duplicate_row_value_rejected(self):
        self.mutate_table(lambda r: ET.SubElement(r.find("node/row"), "process", ref="p"))
        with self.assertRaisesRegex(ValueError, "duplicate row process"):
            self.analyze()

    def test_wrong_schema_rejected(self):
        self.table.write_text(table_xml().replace("sample-time</engineering-type>", "milliseconds</engineering-type>"))
        with self.assertRaisesRegex(ValueError, "column schema"):
            self.analyze()

    def test_column_order_and_coarse_toc_dates_rejected(self):
        def reverse(root):
            schema = root.find("node/schema")
            schema[:] = list(reversed(list(schema)))
        self.mutate_table(reverse)
        with self.assertRaisesRegex(ValueError, "column schema"):
            self.analyze()
        self.table.write_text(table_xml())
        self.toc.write_text(toc_xml().replace(".000-04:00", "-04:00"))
        with self.assertRaisesRegex(ValueError, "precision"):
            self.analyze()

    def test_kernel_clock_uncertainty_included(self):
        self.samples[5]["clock_read_uncertainty_seconds"] = .001
        result = self.analyze()
        self.assertEqual(result["clock"]["kernel_clock_uncertainty_seconds"], .001)
        self.assertAlmostEqual(result["clock"]["mapping_uncertainty_seconds"] - result["clock"]["trace_mapping_uncertainty_seconds"], .001)

    def test_missing_or_cyclic_reference_rejected(self):
        for reference in ("absent", "cycle"):
            with self.subTest(reference=reference):
                self.table.write_text(table_xml().replace('ref="w"', f'ref="{reference}"'))
                if reference == "cycle":
                    self.mutate_table(lambda r: ET.SubElement(r.find("node"), "weight", id="cycle", ref="cycle"))
                with self.assertRaises(ValueError):
                    self.analyze()

    def test_duplicate_reference_id_rejected(self):
        self.mutate_table(lambda r: ET.SubElement(r.find("node"), "weight", id="w"))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.analyze()

    def test_typed_reference_rejected(self):
        self.table.write_text(table_xml().replace('ref="w"', 'ref="p"'))
        with self.assertRaisesRegex(ValueError, "value type"):
            self.analyze()

    def test_pid_contamination_rejected(self):
        self.mutate_table(lambda r: setattr(r.find("node/row/process/pid"), "text", "999"))
        with self.assertRaisesRegex(ValueError, "other than"):
            self.analyze()

    def test_thread_process_mismatch_rejected(self):
        def change(root):
            thread = root.find("node/row/thread")
            thread.remove(thread.find("process"))
            ET.SubElement(ET.SubElement(thread, "process"), "pid").text = "999"
        self.mutate_table(change)
        with self.assertRaisesRegex(ValueError, "Thread process"):
            self.analyze()

    def test_weights_must_be_nanoseconds(self):
        self.table.write_text(table_xml().replace('fmt="1.00 ms"', 'fmt="1.00 s"'))
        with self.assertRaisesRegex(ValueError, "not nanoseconds"):
            self.analyze()

    def test_waiting_rows_do_not_count(self):
        def change(root):
            row = root.findall("node/row")[2]
            row.remove(row.find("thread-state"))
            ET.SubElement(row, "thread-state").text = "Waiting"
        self.mutate_table(change)
        result = self.analyze()
        self.assertEqual(result["phases"][0]["total"]["sample_count"], 1)
        self.assertEqual(result["recording_quality"]["target_states"]["Waiting"], 1)

    def test_missing_symbols_retained_not_fabricated(self):
        def change(root):
            for frame in root.iter("frame"):
                if "name" in frame.attrib:
                    frame.set("name", "0xabcdef")
        self.mutate_table(change)
        result = self.analyze()
        self.assertEqual(result["status"], "analysis_pending")
        self.assertFalse(result["regression_passed"])
        self.assertEqual(result["phases"][0]["quality"]["unknown_leaf_weight_ns"], 2_000_000)

    def test_missing_stacks_reported(self):
        def change(root):
            for row in root.findall("node/row"):
                row.remove(row.find("tagged-backtrace"))
        self.mutate_table(change)
        result = self.analyze()
        self.assertEqual(result["status"], "analysis_pending")
        self.assertEqual(result["phases"][0]["quality"]["missing_stack_weight_ns"], 2_000_000)
        self.assertEqual(result["phases"][0]["top_leaf_symbols"][0]["symbol"], "<missing stack>")

    def test_outside_duration_and_unbracketed_phase_rejected(self):
        self.table.write_text(table_xml().replace("9000000000", "11000000000"))
        with self.assertRaisesRegex(ValueError, "outside trace"):
            self.analyze()
        self.table.write_text(table_xml())
        self.windows["arrival"]["end_monotonic_seconds"] = 109.5
        with self.assertRaisesRegex(ValueError, "bracket the phase"):
            self.analyze()

    def test_nonfinite_or_zero_phase_rejected(self):
        for value in (float("nan"), 102):
            self.windows["arrival"]["end_monotonic_seconds"] = value
            with self.assertRaises(ValueError):
                self.analyze()

    def test_kernel_birth_gap_and_regression_rejected(self):
        for key, value in (("birth_time_us", 999), ("cpu_seconds", -1), ("mach_absolute_seconds", 999), ("clock_read_uncertainty_seconds", .1), ("process_id", 999)):
            with self.subTest(key=key):
                self.samples = kernel_samples()
                self.samples[5][key] = value
                with self.assertRaises(ValueError):
                    self.analyze()
        self.samples = kernel_samples()
        del self.samples[4:7]
        with self.assertRaisesRegex(ValueError, "gap"):
            self.analyze()

    def test_bridge_drift_or_missing_bridge_rejected(self):
        del self.anchor["mach_clock_end"]
        with self.assertRaisesRegex(ValueError, "Both paired"):
            self.analyze()
        self.anchor = anchor()
        self.anchor["mach_clock_end"]["absolute_minus_monotonic_seconds"] += .01
        self.anchor["mach_clock_end"]["mach_ticks"] += 10_000_000
        with self.assertRaisesRegex(ValueError, "drift"):
            self.analyze()

    def test_toc_timezone_and_uncertainty_preserved(self):
        result = self.analyze()
        self.assertEqual(result["clock"]["trace_origin_python_monotonic_seconds"], 100)
        self.assertGreater(result["phases"][0]["edge_uncertainty"]["seconds"], .001)
        self.assertEqual(profile.epoch_ns(START), profile.epoch_ns("2026-10-02T14:00:00+00:00"))
        with self.assertRaisesRegex(ValueError, "time zone"):
            profile.epoch_ns("2026-10-02T14:00:00")

    def test_entities_size_and_element_count_rejected(self):
        self.table.write_text('<!DOCTYPE x [<!ENTITY test "text">]><trace-query-result/>')
        with self.assertRaisesRegex(ValueError, "declarations"):
            self.analyze()
        self.table.write_text(table_xml())
        with patch.object(profile, "MAX_PROFILE_BYTES", 8):
            with self.assertRaisesRegex(ValueError, "size bound"):
                self.analyze()
        with patch.object(profile, "MAX_XML_ELEMENTS", 1):
            with self.assertRaisesRegex(ValueError, "element count"):
                self.analyze()


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.deadline = Mock(end=10**12)
        self.deadline.remaining.side_effect = lambda maximum=None: min(maximum or 300, 300)
        self.deadline.interrupt_at.side_effect = lambda end: nullcontext()

    def exporter(self, command, **kwargs):
        destination = Path(command[command.index("--output") + 1])
        destination.write_text(toc_xml() if "--toc" in command else table_xml())
        process = Mock(returncode=0, pid=900)
        process.poll.return_value = 0
        return process

    def test_two_bounded_exports_persist_hashes_and_analysis(self):
        with patch.object(profile.subprocess, "Popen", side_effect=self.exporter) as launched:
            result = profile.analyze_trace(self.root / "cpu.trace", self.root / "analysis", PID,
                                          {"arrival": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}},
                                          anchor(), kernel_samples(), self.deadline)
        self.assertEqual(launched.call_count, 2)
        self.assertEqual(len(result["exports"]), 2)
        self.assertEqual(len(result["exports"][0]["output_sha256"]), 64)
        self.assertTrue((self.root / "analysis/cpu-attribution.json").is_file())
        self.assertTrue(launched.call_args.kwargs["start_new_session"])

    def test_refuses_overwrite(self):
        destination = self.root / "toc.xml"
        destination.write_text("existing")
        with patch.object(profile.subprocess, "Popen") as launched:
            with self.assertRaisesRegex(ValueError, "overwrite"):
                profile.bounded_export("cpu.trace", destination, "toc", self.deadline)
        launched.assert_not_called()

    def test_export_failure_does_not_analyze(self):
        process = Mock(returncode=7)
        process.poll.return_value = 7
        with patch.object(profile.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(ValueError, "exit 7"):
                profile.bounded_export("cpu.trace", self.root / "toc.xml", "toc", self.deadline)

    def test_timeout_kills_only_owned_exporter_group(self):
        process = Mock(pid=900)
        process.poll.return_value = None
        self.deadline.remaining.side_effect = [0, 0]
        with patch.object(profile.subprocess, "Popen", return_value=process), patch.object(profile.os, "getpgid", return_value=900), patch.object(profile.os, "killpg") as killed:
            with self.assertRaises(TimeoutError):
                profile.bounded_export("cpu.trace", self.root / "toc.xml", "toc", self.deadline)
        killed.assert_called_once_with(900, profile.signal.SIGKILL)

    def test_cleanup_exit_race_preserves_original_timeout(self):
        process = Mock(pid=900)
        process.poll.return_value = None
        self.deadline.remaining.side_effect = [0, 0]
        with patch.object(profile.subprocess, "Popen", return_value=process), patch.object(profile.os, "getpgid", side_effect=ProcessLookupError), patch.object(profile.os, "killpg") as killed:
            with self.assertRaises(TimeoutError):
                profile.bounded_export("cpu.trace", self.root / "toc.xml", "toc", self.deadline)
        killed.assert_not_called()
        process.wait.assert_called_once_with(timeout=2)

    def test_oversized_export_rejected_even_after_exit(self):
        def huge(command, **kwargs):
            process = self.exporter(command, **kwargs)
            Path(command[command.index("--output") + 1]).write_bytes(b"x" * 11)
            return process
        with patch.object(profile, "MAX_TOC_BYTES", 10), patch.object(profile.subprocess, "Popen", side_effect=huge):
            with self.assertRaisesRegex(ValueError, "excessive export"):
                profile.bounded_export("cpu.trace", self.root / "toc.xml", "toc", self.deadline)


if __name__ == "__main__":
    unittest.main()
