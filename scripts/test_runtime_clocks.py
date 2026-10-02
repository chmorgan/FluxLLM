"""Runtime clock/evidence boundary tests; no native process launches."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import runtime_attribution as runtime
from test_runtime_time_profile import anchor, kernel_samples


def phase_report():
    # Clock tests retain their independent 1% CPU signal; profiler fixtures use
    # a lower default rate so their sample weights agree with kernel counters.
    samples = kernel_samples(cpu_percent=1)
    return {"samples": samples, "owned_identity": {"process_id": 1234, "birth_time_us": 123456},
            "runtime": {key: value for key, value in anchor().items() if key.startswith("mach_clock")}}


class ClockTests(unittest.TestCase):
    def test_kernel_phase_uses_paired_mach_epoch(self):
        report = phase_report()
        result = runtime.phase_cpu(report, {"steady": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}})
        self.assertAlmostEqual(result["steady"]["cpu_seconds"], .02)
        self.assertAlmostEqual(result["steady"]["average_cpu_percent"], 1)
        self.assertAlmostEqual(result["steady"]["rolling_1s_percent"], 1)

    def test_valid_collector_timeline_does_not_hide_bad_mach_evidence(self):
        for field, bad in (("mach_absolute_seconds", 999), ("mach_absolute_ticks", 1),
                           ("mach_timebase_numer", 2), ("mach_timebase_denom", 2),
                           ("clock_read_uncertainty_seconds", .002)):
            report = phase_report()
            report["samples"][4][field] = bad
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.phase_cpu(report, {"steady": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}})

    def test_identity_and_bridge_drift_rejected(self):
        for change in ("birth", "offset", "ticks"):
            report = phase_report()
            if change == "birth":
                report["owned_identity"]["birth_time_us"] += 1
            elif change == "offset":
                report["runtime"]["mach_clock_end"]["absolute_minus_monotonic_seconds"] += 1
            else:
                report["runtime"]["mach_clock_end"]["mach_ticks"] += 10000000
            with self.subTest(change=change), self.assertRaises(ValueError):
                runtime.phase_cpu(report, {"steady": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}})

    def test_stale_valid_bridges_cannot_measure_current_window(self):
        report = phase_report()
        for clock in ("mach_clock_start", "mach_clock_end"):
            report["runtime"][clock]["monotonic_seconds"] -= 20
            report["runtime"][clock]["mach_ticks"] -= 20_000_000_000
        with self.assertRaisesRegex(ValueError, "outside its paired"):
            runtime.phase_cpu(report, {"steady": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}})

    def test_incomplete_summary_preserves_missing_metrics(self):
        text = runtime.summary({"operation": "compare", "status": "diagnostic_incomplete", "errors": ["capture failed"],
            "cases": [{"label": "failed", "phase_cpu": None, "runtime_cpu_target": None, "peak_footprint_bytes": None}]})
        self.assertIn("capture failed", text)
        self.assertIn("unavailable", text)
        self.assertIn("not evaluated", text)

    def test_phase_boundaries_require_native_visibility_and_unique_kernel_samples(self):
        report = phase_report()
        samples = report["samples"]
        for index in range(21, 63):
            sample = copy.deepcopy(samples[0])
            sample.update(monotonic_seconds=500 + index / 2, mach_absolute_seconds=110 + index / 2,
                          mach_absolute_ticks=int((110 + index / 2) * 1e9), cpu_seconds=index * .005)
            samples.append(sample)
        final_bridge = report["runtime"]["mach_clock_end"]
        final_bridge.update(monotonic_seconds=132, mach_ticks=142000000000)
        points = []
        for index in range(31):
            sample = samples[index * 2]
            points.append({"label": "before-traffic" if index == 0 else "completion-end" if index == 30 else "during-traffic",
                "python_monotonic_seconds": 100 + index, "resource_sample": sample,
                "snapshot": {"dashboard_visible": True, "popover_visible": True,
                             "runner_collector_sample_monotonic_seconds": sample["monotonic_seconds"]}})
        report["runtime"]["checkpoints"] = points
        report["workload"] = {"fixture_status": {"timing": {"streams": [
            {"first_write_started_monotonic_seconds": 100.5, "terminal_write_started_monotonic_seconds": 125.5},
            {"first_write_started_monotonic_seconds": 100.6, "terminal_write_started_monotonic_seconds": 125.6}]}}}
        windows = runtime.phase_windows(report)
        self.assertEqual(windows["whole_contiguous_runtime"], {"start_monotonic_seconds": 100, "end_monotonic_seconds": 130})
        for mutation in ("hidden", "gap", "unpaired", "birth", "tail"):
            changed = copy.deepcopy(report)
            points = changed["runtime"]["checkpoints"]
            if mutation == "hidden":
                points[3]["snapshot"]["popover_visible"] = False
            elif mutation == "gap":
                del points[3:5]
            elif mutation == "unpaired":
                points[3]["snapshot"]["runner_collector_sample_monotonic_seconds"] += .1
            elif mutation == "birth":
                points[3]["resource_sample"]["birth_time_us"] += 1
            else:
                changed["workload"]["fixture_status"]["timing"]["streams"][0]["terminal_write_started_monotonic_seconds"] = 129
                changed["workload"]["fixture_status"]["timing"]["streams"][1]["terminal_write_started_monotonic_seconds"] = 129
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runtime.phase_windows(changed)

    def test_nested_deadline_restores_remaining_outer_time(self):
        now = [10.0]
        deadline = runtime.RuntimeDeadline(clock=lambda: now[0])
        with mock.patch.object(runtime.signal, "getsignal", return_value="old"), \
                mock.patch.object(runtime.signal, "signal"), \
                mock.patch.object(runtime.signal, "setitimer", side_effect=[(20, 0), (0, 0), (0, 0)]) as timer:
            with deadline.interrupt_at(15):
                now[0] = 13
        self.assertEqual(timer.call_args_list[-1].args[1:], (17, 0))

    def test_profile_cleanup_never_exposes_comparison_cpu(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(), "normal", profile=True)
            diagnostic.report["workload_cpu"] = {"available": True, "average_cpu_percent": 4}
            with mock.patch.object(runtime.memory.MemoryDiagnostic, "cleanup"):
                diagnostic.cleanup()
            self.assertFalse(diagnostic.report["workload_cpu"]["available"])
            self.assertEqual(diagnostic.report["profiled_kernel_cpu"]["average_cpu_percent"], 4)

    def test_collector_extension_is_local_and_does_not_replace_global_class(self):
        original = runtime.app.Collector
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(), "normal")
            with mock.patch.object(runtime, "RuntimeCollector", return_value="collector") as collector:
                self.assertEqual(diagnostic.create_collector("arg"), "collector")
            collector.assert_called_once_with("arg", owner=diagnostic)
        self.assertIs(runtime.app.Collector, original)


if __name__ == "__main__":
    unittest.main()
