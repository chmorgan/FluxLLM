"""Fail-closed GPU sampling checks; every external command is mocked."""

import math
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import performance_gpu_sample as gpu_sample


GPU_FIELDS = (
    "gpu_execution_seconds", "gpu_percent", "gpu_rolling_1s_percent",
)


class PowermetricsSessionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.session_count = 0
        self.clock = self.enterContext(patch.object(gpu_sample.time, "monotonic", return_value=100.0))
        self.enterContext(patch.object(gpu_sample, "_clock_pair", return_value={
            "absolute_minus_monotonic_seconds": 0.0, "uncertainty_seconds": 0.0,
        }))
        for name in ("Popen", "run", "check_output"):
            self.enterContext(patch.object(gpu_sample.subprocess, name,
                side_effect=AssertionError("The GPU unit tests must not execute external commands")))
        self.probe = self.enterContext(patch.object(gpu_sample.PowermetricsSession, "_probe", return_value={
            "exit_code": 1, "timed_out": False, "authorization": "denied", "raw_bytes": 0,
        }))

    def session(self, deadline=200.0):
        self.session_count += 1
        return gpu_sample.PowermetricsSession(self.output / str(self.session_count), deadline)

    def registered_session(self, probe=None):
        if probe is not None:
            self.probe.return_value = probe
        session = self.session()
        session.start()
        session.register_process(123, 456_000_000, 100.0)
        session.add_window("active", 123, 456_000_000, 100.0, 102.0)
        session.register_exit(123, 456_000_000, 102.0, 102.5, 0)
        return session

    def assert_unavailable(self, result):
        self.assertIs(result["valid"], False)
        self.assertEqual(result["implementation_status"], "capability_probe_only")
        self.assertIs(result["calibration"]["performed"], False)
        self.assertIs(result["calibration"]["valid"], False)
        self.assertTrue(result["invalid"], "Unavailability must retain an explicit explanation")
        window = result["windows"]["active"]
        self.assertIs(window["coverage_complete"], False)
        self.assertTrue(window["invalid"])
        for field in GPU_FIELDS:
            for suffix in ("", "_lower_bound", "_upper_bound"):
                name = field + suffix
                self.assertIn(name, window)
                self.assertIsNone(window[name], name + " must not fabricate measured zero")
        terminal = result["final_exit_coverage"]["active"]
        self.assertIs(terminal["complete"], False)
        self.assertTrue(terminal["invalid"])

    def test_authorization_denial_preserves_null_gpu_bounds(self):
        self.assert_unavailable(self.registered_session().finish())
        self.probe.assert_called_once()

    def test_successful_raw_probe_is_not_validated_process_gpu_measurement(self):
        session = self.registered_session({
            "exit_code": 0, "timed_out": False, "authorization": "root", "raw_bytes": 128,
        })
        self.assert_unavailable(session.finish())
        self.probe.assert_called_once()

    def test_probe_timeout_preserves_unknown_values(self):
        session = self.registered_session({
            "exit_code": None, "timed_out": True, "authorization": "root", "raw_bytes": 0,
        })
        self.assert_unavailable(session.finish())

    def test_empty_successful_probe_is_not_explicit_zero(self):
        session = self.registered_session({
            "exit_code": 0, "timed_out": False, "authorization": "root", "raw_bytes": 0,
        })
        self.assert_unavailable(session.finish())

    def test_nonzero_probe_exit_preserves_unknown_values(self):
        session = self.registered_session({
            "exit_code": 2, "timed_out": False, "authorization": "root", "raw_bytes": 128,
        })
        self.assert_unavailable(session.finish())

    def test_expired_deadline_does_not_launch_probe(self):
        for deadline in (99.0, 100.0):
            with self.subTest(deadline=deadline):
                session = self.session(deadline)
                result = session.start()
                self.assertIs(result["available"], False)
                self.assertTrue(any("deadline" in item.lower() for item in result["invalid"]))
        self.probe.assert_not_called()

    def test_start_never_claims_validated_capability_or_opens_secure_prompt(self):
        self.probe.return_value = {
            "exit_code": 0, "timed_out": False, "authorization": "already-root", "raw_bytes": 128,
        }
        session = self.session()
        result = session.start()
        self.assertIs(result["available"], False)
        self.assertIs(result["secure_prompt_opened"], False)
        self.assertEqual(result["implementation_status"], "capability_probe_only")
        self.assertIn(gpu_sample.SCHEMA_REASON, result["invalid"])
        self.assertEqual(session.start(), result)
        self.probe.assert_called_once()

    def test_reused_pid_with_different_birth_time_is_rejected(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        with self.assertRaises(ValueError):
            session.register_process(123, 456_000_001, 100.0)

    def test_window_requires_registered_pid_and_matching_birth(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        for pid, birth in ((999, 456_000_000), (123, 456_000_001)):
            with self.subTest(pid=pid, birth=birth):
                with self.assertRaises(ValueError):
                    session.add_window("active", pid, birth, 100.0, 102.0)

    def test_invalid_and_duplicate_windows_are_rejected(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        for name, start, end in (("", 100.0, 102.0), ("active", 101.0, 100.0),
                                 ("active", 100.0, 100.0), ("active", math.nan, 102.0),
                                 ("active", 100.0, math.inf)):
            with self.subTest(name=name, start=start, end=end):
                with self.assertRaises(ValueError):
                    session.add_window(name, 123, 456_000_000, start, end)
        session.add_window("active", 123, 456_000_000, 100.0, 102.0)
        with self.assertRaises(ValueError):
            session.add_window("active", 123, 456_000_000, 102.0, 104.0)

    def test_exit_requires_matching_process_identity(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        with self.assertRaises(ValueError):
            session.register_exit(123, 456_000_001, 102.0, 102.5, 0)

    def test_invalid_exit_drain_or_time_is_rejected(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        for final, drain in ((102.0, 101.0), (math.nan, 103.0), (102.0, math.inf)):
            with self.subTest(final=final, drain=drain):
                with self.assertRaises(ValueError):
                    session.register_exit(123, 456_000_000, final, drain, 0)

    def test_window_cannot_precede_registered_process(self):
        session = self.session()
        session.register_process(123, 456_000_000, 100.0)
        with self.assertRaises(ValueError):
            session.add_window("active", 123, 456_000_000, 99.0, 101.0)

    def test_probe_cleanup_escalates_only_its_own_process_after_timeout(self):
        session = self.session()
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = [gpu_sample.subprocess.TimeoutExpired("mock probe", .2), 0]
        session.process = process
        session._cleanup_probe()
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_count, 2)
        self.assertFalse(session.invalid)

    def test_unconfirmed_cleanup_is_retained_in_unavailable_report(self):
        session = self.registered_session()
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = gpu_sample.subprocess.TimeoutExpired("mock probe", .2)
        session.process = process
        result = session.finish()
        self.assert_unavailable(result)
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
        self.assertTrue(any("cleanup was not confirmed" in item for item in result["invalid"]))

    def test_finish_is_idempotent_and_does_not_probe_again(self):
        session = self.registered_session()
        first = session.finish()
        self.assert_unavailable(first)
        second = session.finish()
        self.assertEqual(first, second)
        self.probe.assert_called_once()


if __name__ == "__main__":
    unittest.main()
