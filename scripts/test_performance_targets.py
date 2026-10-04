"""Selection and provenance gates for the separated production-core harness."""
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import app_performance as app
import drawing_attribution as drawing
import runtime_attribution as runtime


class PerformanceTargetTests(unittest.TestCase):
    def test_release_builder_selects_harness_even_when_desktop_exists(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("FluxLLMApp", "FluxLLMPerformanceApp", "FluxLLMResourceCollector"):
                (root / name).write_bytes(name.encode())
            (root / "FluxLLMPackageTests.xctest").mkdir()
            with patch.object(app, "execute_logged", return_value={"exit_code": 0}), \
                    patch.object(app.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=str(root), stderr="")):
                paths, hashes, result = app.build_products(root, 1)
            self.assertEqual(paths["app"].name, "FluxLLMPerformanceApp")
            self.assertEqual(hashes["app"]["sha256"], app.path_hash(root / "FluxLLMPerformanceApp"))
            self.assertNotEqual(hashes["app"]["sha256"], app.path_hash(root / "FluxLLMApp"))

    def test_release_builder_does_not_fall_back_to_desktop_when_harness_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "FluxLLMApp").write_bytes(b"desktop")
            (root / "FluxLLMTests.xctest").mkdir()
            with patch.object(app, "execute_logged", return_value={"exit_code": 0}), \
                    patch.object(app.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=str(root), stderr="")):
                with self.assertRaisesRegex(app.InvalidResult, "FluxLLMPerformanceApp"):
                    app.build_products(root, 1)

    def test_frozen_target_selection_uses_provenance_and_preserves_archives(self):
        root = Path("/frozen")
        self.assertEqual(app.frozen_performance_executable(root, {}), root / "FluxLLMApp")
        self.assertEqual(app.frozen_performance_executable(root, {"performance_executable": "FluxLLMPerformanceApp"}),
                         root / "FluxLLMPerformanceApp")
        for name in ("other", "../FluxLLMApp", "/FluxLLMApp"):
            with self.assertRaises(app.InvalidResult):
                app.frozen_performance_executable(root, {"performance_executable": name})

    def test_current_products_reject_retired_modes_while_archives_keep_capabilities(self):
        current = {"supported_graphics_modes": ["normal"]}
        app.validate_graphics_mode(current, "normal")
        app.validate_graphics_mode({}, "runtime-metal-full-chart")
        with self.assertRaisesRegex(app.InvalidResult, "does not support graphics mode"):
            app.validate_graphics_mode(current, "runtime-metal-full-chart")
        for value in ([], "normal", ["normal", "normal"], [{"name": "normal"}]):
            with self.assertRaises(app.InvalidResult):
                app.validate_graphics_mode({"supported_graphics_modes": value}, "normal")

    def test_release_and_frozen_bundles_keep_toolchain_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(app.InvalidResult):
                app.release_test_bundle(root)
            (root / "FluxLLMPackageTests.xctest").mkdir()
            self.assertEqual(app.release_test_bundle(root).name, "FluxLLMPackageTests.xctest")
            (root / "FluxLLMTests.xctest").mkdir()
            self.assertEqual(app.release_test_bundle(root).name, "FluxLLMTests.xctest")
            self.assertEqual(app.frozen_test_bundle(root, {}).name, "FluxLLMPackageTests.xctest")
            self.assertEqual(app.frozen_test_bundle(root, {"test_bundle": "FluxLLMTests.xctest"}).name, "FluxLLMTests.xctest")
            with self.assertRaises(app.InvalidResult):
                app.frozen_test_bundle(root, {"test_bundle": "../other.xctest"})

    def test_adapter_identity_binds_support_entry_point_and_target_graph(self):
        sources = app.adapter_identity()["sources"]
        self.assertIn("Package.swift", sources)
        self.assertIn("Sources/FluxLLMPerformanceApp/FluxLLMPerformanceApp.swift", sources)
        self.assertIn("Sources/FluxLLMPerformanceSupport/PerformanceControl.swift", sources)
        self.assertIn("Sources/FluxLLMPerformanceSupport/PerformanceHistoryFixture.swift", sources)
        self.assertNotIn("Sources/FluxLLMApp/FluxLLMApp.swift", sources)
        graph = (app.ROOT / "Package.swift").read_text()
        desktop = graph[graph.index('name: "FluxLLMApp"'):graph.index('path: "Sources/FluxLLMApp"')]
        self.assertIn('dependencies: ["FluxLLM"]', desktop)
        self.assertNotIn("FluxLLMPerformanceSupport", desktop)

    def test_current_defaults_use_retained_production_paths(self):
        args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
                                           "--collector-binary", "/collector", "--provenance", "/provenance"])
        self.assertEqual(runtime.selected_cases(args), [("baseline-before", "normal"),
                                                       ("normal", "normal"), ("baseline-after", "normal")])
        self.assertEqual(drawing.DEFAULT_CASES, ("canvas:empty", "canvas:line", "core-graphics:line"))


if __name__ == "__main__":
    unittest.main()
