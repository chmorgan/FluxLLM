"""Frozen runtime version comparisons never launch native tools in these tests."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runtime_attribution as runtime


class RuntimeVersionTests(unittest.TestCase):
    def argv(self, directory):
        root = Path(directory)
        return ["compare", "--app-binary", str(root / "candidate/app"),
                "--test-bundle", str(root / "candidate/tests"), "--provenance", str(root / "candidate/provenance.json"),
                "--collector-binary", str(root / "collector"), "--baseline-mode", "normal",
                "--reference-app-binary", str(root / "reference/app"),
                "--reference-test-bundle", str(root / "reference/tests"),
                "--reference-provenance", str(root / "reference/provenance.json"),
                "--output-dir", str(root / "output")]

    def run_comparison(self, directory, *, mismatch=None, mutation=None, visual_mismatch=False,
                       peaks=(4, 3, 4), deadline_calls=None, candidate_mode=None, seen_modes=None):
        root = Path(directory)
        for role in ("reference", "candidate"):
            folder = root / role
            folder.mkdir()
            for name in ("app", "tests", "provenance.json"):
                (folder / name).write_text(role + name)
            (folder / "assets.bundle").mkdir()
            (folder / "assets.bundle/data").write_text(role + "resource")
        (root / "collector").write_text("common collector")
        seen = []
        def products(args):
            role = args.app_binary.parent.name
            paths = {"app": args.app_binary, "tests": args.test_bundle, "collector": args.collector_binary}
            provenance = {"provenance_file": str(args.provenance), "fixture_equivalence_sha256": {"populated": "f" * 64},
                          "resource_bundle_sha256": {"assets.bundle": "hash"}, "version": role}
            identity = {"sha256": "common measurement"}
            if role == "reference":
                if mismatch == "fixture":
                    provenance["fixture_equivalence_sha256"]["populated"] = "a" * 64
                elif mismatch == "measurement":
                    identity["sha256"] = "other measurement"
                elif mismatch == "collector":
                    paths["collector"] = root / "other-collector"
            return paths, provenance, identity
        def capture(path, mode, paths, provenance, identity, deadline, *, profile):
            self.assertFalse(profile)
            role = paths["app"].parent.name
            self.assertEqual(mode, candidate_mode if role == "candidate" and candidate_mode else "normal")
            if seen_modes is not None:
                seen_modes.append((role, mode))
            self.assertLessEqual(deadline.end - deadline.clock(), runtime.THREE_CASE_SECONDS)
            seen.append(paths["app"].parent.name)
            case = {"status": "diagnostic_captured", "errors": [], "samples": [],
                    "phase_cpu": {"whole_contiguous_runtime": {"average_cpu_percent": 3, "rolling_1s_percent": peaks[len(seen) - 1]}},
                    "visual_work": {"requests": [1, 2]}, "runtime_cpu_target": {"evaluated": True, "within_limit": True}}
            if visual_mismatch and len(seen) == 2:
                case["visual_work"]["requests"] = [3, 4]
            path.mkdir()
            runtime.write_json(path / "runtime-case.json", case)
            if mutation and len(seen) == 1:
                (root / mutation).write_text("changed during capture")
            return copy.deepcopy(case)
        with patch.object(runtime.sys, "platform", "darwin"), \
                patch.object(runtime, "runtime_source_identity", return_value={}), \
                patch.object(runtime.memory, "validate_products", side_effect=products), \
                patch.object(runtime, "capture_case", side_effect=capture), \
                patch.object(runtime, "RuntimeDeadline", wraps=runtime.RuntimeDeadline) as deadlines, \
                contextlib.redirect_stdout(io.StringIO()):
            arguments = self.argv(directory)
            if candidate_mode is not None:
                arguments += ["--candidate-mode", candidate_mode]
            code = runtime.run(arguments)
        if deadline_calls is not None:
            deadline_calls.extend(deadlines.call_args_list)
        return code, json.loads((root / "output/runtime-report.json").read_text()), seen

    def test_versions_run_reference_candidate_reference_with_same_normal_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            code, report, seen = self.run_comparison(directory)
        self.assertEqual(code, 0)
        self.assertEqual(seen, ["reference", "candidate", "reference"])
        self.assertEqual(report["operation"], "version-compare")
        self.assertEqual([row["label"] for row in report["cases"]], ["reference-before", "candidate", "reference-after"])
        self.assertEqual([row["product_role"] for row in report["cases"]], seen)
        self.assertTrue(report["baseline_drift"]["comparison_conclusive"])
        for product in report["products"].values():
            self.assertEqual(set(product["files"]), {"app", "tests", "collector", "provenance", "resource:assets.bundle"})
        self.assertFalse(report["regression_passed"])

    def test_three_version_cases_receive_70_seconds_inside_300_second_command(self):
        deadline_calls = []
        with tempfile.TemporaryDirectory() as directory:
            code, report, seen = self.run_comparison(directory, deadline_calls=deadline_calls)
        self.assertEqual(code, 0)
        self.assertEqual(len(seen), 3)
        self.assertEqual(len(deadline_calls), 4)
        self.assertEqual(deadline_calls[0].args, ())
        self.assertEqual(deadline_calls[0].kwargs, {})
        self.assertTrue(all(call.args == (70,) and call.kwargs == {"cleanup_reserve": 8}
                            for call in deadline_calls[1:]))
        self.assertEqual(runtime.RuntimeDeadline(clock=lambda: 10).end, 310)
        self.assertEqual(report["deadline_seconds"], 300)
        self.assertEqual(runtime.CASE_SECONDS, 54)
        self.assertEqual(runtime.PROFILE_SECONDS, 120)
        self.assertLess(3 * runtime.THREE_CASE_SECONDS + 15, runtime.MAX_SECONDS)

    def test_full_metal_candidate_uses_its_mode_between_unchanged_reference_modes(self):
        modes = []
        with tempfile.TemporaryDirectory() as directory:
            code, report, seen = self.run_comparison(directory, candidate_mode="runtime-metal-full-chart", seen_modes=modes)
        self.assertEqual(code, 0)
        self.assertEqual(seen, ["reference", "candidate", "reference"])
        self.assertEqual(modes, [("reference", "normal"), ("candidate", "runtime-metal-full-chart"), ("reference", "normal")])
        self.assertEqual([row["mode"] for row in report["cases"]], [mode for _, mode in modes])
        self.assertTrue(report["baseline_drift"]["comparison_conclusive"])
        self.assertFalse(report["regression_passed"])

    def test_candidate_mode_requires_complete_frozen_reference_comparison(self):
        args = self.argv("/tmp/runtime-candidate-mode-test")
        for flag in ("--reference-app-binary", "--reference-test-bundle", "--reference-provenance"):
            offset = args.index(flag)
            del args[offset:offset + 2]
        args += ["--candidate-mode", "runtime-metal-full-chart"]
        with self.assertRaises(ValueError):
            runtime.selected_cases(runtime.parser().parse_args(args))

    def test_partial_reference_and_profile_or_controls_rejected_before_capture(self):
        for alteration in ("partial", "profile", "controls"):
            args = self.argv("/tmp/runtime-version-test")
            if alteration == "partial":
                offset = args.index("--reference-test-bundle")
                del args[offset:offset + 2]
            elif alteration == "profile":
                args[0] = "profile"
            else:
                args += ["--controls", "runtime-optimized"]
            with self.subTest(alteration=alteration), self.assertRaises(ValueError):
                runtime.selected_cases(runtime.parser().parse_args(args))

    def test_mismatched_common_contracts_prevent_all_captures(self):
        for mismatch in ("fixture", "measurement", "collector"):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                code, report, seen = self.run_comparison(directory, mismatch=mismatch)
            self.assertEqual(code, 1)
            self.assertEqual(seen, [])
            self.assertEqual(report["status"], "diagnostic_incomplete")
            self.assertTrue(report["errors"])

    def test_all_versions_and_resources_rechecked_immediately_after_capture(self):
        for mutation in ("candidate/app", "reference/tests", "collector", "candidate/provenance.json", "reference/assets.bundle/data"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                code, report, seen = self.run_comparison(directory, mutation=mutation)
            self.assertEqual(code, 1)
            self.assertEqual(seen, ["reference"])
            self.assertTrue(any("Frozen products changed" in error for error in report["errors"]))

    def test_deterministic_visual_request_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            code, report, seen = self.run_comparison(directory, visual_mismatch=True)
        self.assertEqual(code, 1)
        self.assertEqual(seen, ["reference", "candidate"])
        self.assertTrue(any("identical deterministic visual requests" in error for error in report["errors"]))

    def test_reference_drift_stays_inconclusive_and_three_cases_are_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            code, report, _ = self.run_comparison(directory, peaks=(4, 3, 6))
        self.assertEqual(code, 0)
        self.assertFalse(report["baseline_drift"]["comparison_conclusive"])
        self.assertEqual(len(report["cases"]), 3)
        self.assertEqual(report["deadline_seconds"], 300)
        self.assertLess(3 * runtime.THREE_CASE_SECONDS + 15, runtime.MAX_SECONDS)


if __name__ == "__main__":
    unittest.main()
