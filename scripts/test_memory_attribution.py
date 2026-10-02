"""Synthetic native-report contract checks; no app launch or native inspection."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import memory_attribution as memory
from run_performance_checks import InvalidResult


PID = 1234


def footprint_report():
    # footprint Dirty already includes Swapped. Other columns are not additive;
    # real reports can even show Wired greater than Dirty for one category.
    categories = {
        "Malloc Small": {"dirty": 4096, "swapped": 1024, "clean": 0,
                         "reclaimable": 2048, "wired": 8192, "regions": 2},
        "Owned physical footprint (unmapped) (graphics)": {
            "dirty": 8192, "swapped": 0, "clean": 0,
            "reclaimable": 16384, "wired": 4096, "regions": 3},
        "Future VM category": {"dirty": 123, "swapped": 0, "clean": 456,
                               "reclaimable": 0, "wired": 0, "regions": 1},
    }
    return {"unit": "byte", "bytes per unit": 1, "errors": [], "warnings": [],
            "processes": [{"name": "FluxLLMApp", "pid": PID, "footprint": 12411,
                           "categories": categories,
                           "auxiliary": {"phys_footprint": 12411, "phys_footprint_peak": 16384}}],
            "total footprint": 12411, "summary": copy.deepcopy(categories)}


def native_header(tool):
    return (f"Process:         FluxLLMApp [{PID}]\n"
            "Parent Process:  FluxLLMResourceCollector [1233]\n"
            f"Analysis Tool:   /usr/bin/{tool}\n"
            "Physical footprint:         366.5M\n"
            "Physical footprint (peak):  426.0M\n\n")


def vmmap_report():
    return native_header("vmmap") + """                                VIRTUAL RESIDENT DIRTY SWAPPED VOLATILE NONVOL EMPTY REGION
REGION TYPE                        SIZE SIZE SIZE SIZE SIZE SIZE SIZE COUNT (non-coalesced)
===========                     ======= ======== ===== ======= ======== ====== ===== =======
Malloc Small                      32K 16K 12K 4K 0K 0K 0K 3         see MALLOC ZONE table below
Stack (reserved)                 1024K 0K 0K 0K 0K 0K 0K 1         reserved VM address space (unallocated)
__FONT_DATA                       2352 2352 0K 0K 0K 0K 0K 1
===========                     ======= ======== ===== ======= ======== ====== ===== =======
TOTAL                            1.0M 18K 12K 4K 0K 0K 0K 5
TOTAL, minus reserved VM space    34K 18K 12K 4K 0K 0K 0K 4

MALLOC ZONE                         SIZE SIZE SIZE SIZE COUNT ALLOCATED FRAG SIZE % FRAG COUNT
DefaultMallocZone_0x10177c000        32K 16K 12K 4K 90 10K 6K 38% 3
TOTAL                              32K 16K 12K 4K 90 10K 6K 38% 3
"""


LONG_DESCRIPTION = ("Swift._DictionaryStorage<FluxLLM.(RequestKey in $10094f5c8), "
                    "Swift.Array<FluxLLM.ToolActivityHistory>>  Swift   libswiftCore.dylib")


def heap_report():
    return native_header("heap") + f"""Process {PID}: 6 zones
All zones: 9 nodes malloced - Sizes: 1KB[1] 56[2] 48[1] 40[2] 32[1] 8[2]
All zones: 9 nodes (1312 bytes)

   COUNT      BYTES       AVG   CLASS_NAME                                        TYPE    BINARY
   =====      =====       ===   ==========                                        ====    ======
       2         80      40.0   NSDictionary                                      ObjC    CoreFoundation
       1         48      48.0   NSDictionary                                      ObjC    CoreFoundation
       2        112      56.0                                                     Swift   SwiftUICore
       1       1024    1024.0   {LONG_DESCRIPTION}
       2         16       8.0   non-object
       1         32      32.0   __DataStorage._bytes (malloc)                             Foundation
"""


class DirectToolPlotContractTests(unittest.TestCase):
    def test_candidate_requires_complete_typed_group_and_executed_builds(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        mode = memory.DIRECT_TOOL_PLOT_MODE
        snapshot = drawn_native_gpu_graphics(mode)
        self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
        for invalid in (None, False, 1):
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"]["direct_tool_plot"] = invalid
            with self.subTest(flag=invalid), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, mode)
        for field in memory.DIRECT_TOOL_PLOT_COUNTERS:
            for invalid in (None, True, -1):
                changed = copy.deepcopy(snapshot)
                changed[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(changed, mode)
        snapshot["direct_tool_plot_builds"] = 0
        with self.assertRaisesRegex(InvalidResult, "did not execute geometry"):
            memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_legacy_group_absent_allowed_but_partial_and_direct_normal_rejected(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        snapshot = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
        snapshot["graphics_diagnostics"]["mode"] = "normal"
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        snapshot["graphics_diagnostics"]["direct_tool_plot"] = False
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(snapshot, "normal")
        snapshot.update(direct_tool_plot_builds=0, legacy_tool_plot_builds=3)
        self.assertTrue(memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)["available"])
        snapshot["direct_tool_plot_builds"] = 1
        with self.assertRaisesRegex(InvalidResult, "Legacy tool-plot"):
            memory.validate_graphics(snapshot, "normal")
        snapshot["graphics_diagnostics"]["direct_tool_plot"] = True
        with self.assertRaisesRegex(InvalidResult, "does not match"):
            memory.validate_graphics(snapshot, "normal")
        del snapshot["graphics_diagnostics"]["direct_tool_plot"]
        with self.assertRaisesRegex(InvalidResult, "lack feature metadata"):
            memory.validate_graphics(snapshot, "normal")


class NextRuntimeContractTests(unittest.TestCase):
    def test_ordered_publication_requires_complete_typed_metadata_and_query_evidence(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        mode = memory.ORDERED_PUBLICATION_MODE
        snapshot = drawn_native_gpu_graphics(mode)
        self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
        for invalid in (None, False, 1):
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"]["ordered_chart_publication"] = invalid
            with self.subTest(flag=invalid), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, mode)
        for field in memory.ORDERED_PUBLICATION_COUNTERS:
            for invalid in (None, True, -1):
                changed = copy.deepcopy(snapshot)
                changed[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(changed, mode)
        snapshot["ordered_chart_publication_queries"] = 0
        with self.assertRaisesRegex(InvalidResult, "did not execute queries"):
            memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_ordered_publication_preserves_legacy_shared_and_nonordered_modes(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        for mode, enabled in (("runtime-shared-preparation", True), ("runtime-next-optimized", True), ("runtime-optimized", False)):
            snapshot = drawn_native_gpu_graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            snapshot["graphics_diagnostics"]["ordered_chart_publication"] = enabled
            with self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)
            snapshot.update(ordered_chart_publication_queries=3 if enabled else 0, chart_publication_full_sorts=4)
            # Fallback counts outside the fixed workload are allowed; only its
            # authenticated counter delta proves that benchmark avoided sorts.
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            snapshot["graphics_diagnostics"]["ordered_chart_publication"] = not enabled
            with self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)
            del snapshot["graphics_diagnostics"]["ordered_chart_publication"]
            with self.assertRaisesRegex(InvalidResult, "lack feature metadata"):
                memory.validate_graphics(snapshot, mode)

    def test_normal_accepts_legacy_or_promoted_ordered_publication(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        snapshot = drawn_native_gpu_graphics("runtime-stream-canvas-clock")
        snapshot["graphics_diagnostics"].update(mode="normal", ordered_chart_publication=False)
        snapshot.update(ordered_chart_publication_queries=0, chart_publication_full_sorts=2)
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        snapshot["ordered_chart_publication_queries"] = 1
        with self.assertRaisesRegex(InvalidResult, "Nonordered"):
            memory.validate_graphics(snapshot, "normal")
        snapshot["graphics_diagnostics"]["ordered_chart_publication"] = True
        self.assertTrue(memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)["available"])
        for field in ("unpromised_stream_body_writes", "canvas_frame_clock", "incremental_history_ordering",
                      "optimized_chart_preparation", "shared_chart_preparation", "stable_decoration_hosts"):
            for invalid in (None, not snapshot["graphics_diagnostics"][field]):
                changed = copy.deepcopy(snapshot)
                if invalid is None:
                    del changed["graphics_diagnostics"][field]
                else:
                    changed["graphics_diagnostics"][field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(changed, "normal")
        changed = copy.deepcopy(snapshot)
        changed["graphics_diagnostics"].update(unpromised_stream_body_writes=False, canvas_frame_clock=False)
        changed.update(streamed_bodies_without_promises=0, rail_frame_clock_ticks=0)
        with self.assertRaisesRegex(InvalidResult, "requires stream writes"):
            memory.validate_graphics(changed, "normal")
        del snapshot["graphics_diagnostics"]["ordered_chart_publication"]
        with self.assertRaisesRegex(InvalidResult, "lack feature metadata"):
            memory.validate_graphics(snapshot, "normal")

    def test_normal_ordered_metadata_cannot_disappear_after_acknowledgment(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        snapshot = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
        snapshot["graphics_diagnostics"]["mode"] = "normal"
        diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), "normal")
        diagnostic.validate_graphics_snapshot(snapshot)
        del snapshot["graphics_diagnostics"]["ordered_chart_publication"]
        for field in memory.ORDERED_PUBLICATION_COUNTERS:
            del snapshot[field]
        with self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
            diagnostic.validate_graphics_snapshot(snapshot)

    def test_promoted_normal_requires_paired_paths_and_retains_actual_work_validation(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        snapshot = drawn_native_gpu_graphics("runtime-stream-canvas-clock")
        snapshot["graphics_diagnostics"]["mode"] = "normal"
        validated = memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)
        self.assertTrue(validated["runtime_feature_contract"]["unpromised_stream_body_writes"])
        self.assertTrue(validated["runtime_feature_contract"]["canvas_frame_clock"])
        for field in memory.RUNTIME_FLAGS + memory.NEXT_RUNTIME_FLAGS + ("canvas_frame_clock",):
            for replacement in (None, not snapshot["graphics_diagnostics"][field]):
                changed = copy.deepcopy(snapshot)
                if replacement is None:
                    del changed["graphics_diagnostics"][field]
                else:
                    changed["graphics_diagnostics"][field] = replacement
                with self.subTest(field=field, value=replacement), self.assertRaises(InvalidResult):
                    memory.validate_graphics(changed, "normal", completed_visible_workload=True)
        for field in ("streamed_bodies_without_promises", "rail_frame_clock_ticks"):
            changed = copy.deepcopy(snapshot)
            changed[field] = 0
            with self.subTest(counter=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, "normal", completed_visible_workload=True)
        changed = copy.deepcopy(snapshot)
        changed["graphics_diagnostics"].update(incremental_history_ordering=False, optimized_chart_preparation=False)
        with self.assertRaisesRegex(InvalidResult, "requires both"):
            memory.validate_graphics(changed, "normal")

    def test_normal_preserves_legacy_pair_and_rejects_mid_capture_downgrade(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        promoted = drawn_native_gpu_graphics("runtime-stream-canvas-clock")
        promoted["graphics_diagnostics"]["mode"] = "normal"
        legacy = copy.deepcopy(promoted)
        legacy["graphics_diagnostics"].update(unpromised_stream_body_writes=False, canvas_frame_clock=False)
        legacy.update(streamed_bodies_without_promises=0, rail_frame_clock_ticks=0)
        self.assertTrue(memory.validate_graphics(legacy, "normal")["available"])
        del legacy["graphics_diagnostics"]["canvas_frame_clock"]
        self.assertTrue(memory.validate_graphics(legacy, "normal")["available"])
        diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), "normal")
        diagnostic.validate_graphics_snapshot(promoted)
        with self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
            diagnostic.validate_graphics_snapshot(legacy)

    def test_canvas_clock_modes_require_flag_counters_and_actual_ticks(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        for mode in memory.CANVAS_CLOCK_MODES:
            snapshot = drawn_native_gpu_graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            for invalid in (None, False, 1):
                changed = copy.deepcopy(snapshot)
                changed["graphics_diagnostics"]["canvas_frame_clock"] = invalid
                with self.subTest(mode=mode, flag=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(changed, mode)
            for field in memory.CANVAS_CLOCK_COUNTERS:
                for invalid in (None, True, -1):
                    changed = copy.deepcopy(snapshot)
                    changed[field] = invalid
                    with self.subTest(mode=mode, field=field, value=invalid), self.assertRaises(InvalidResult):
                        memory.validate_graphics(changed, mode)
            snapshot["rail_frame_clock_ticks"] = 0
            with self.assertRaisesRegex(InvalidResult, "did not execute"):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
            snapshot["rail_frame_clock_ticks"] = 3
            snapshot["rail_timeline_content_updates"] = 1
            with self.assertRaisesRegex(InvalidResult, "Timeline"):
                memory.validate_graphics(snapshot, mode)

    def test_legacy_clock_absence_remains_valid_but_supplied_nonclock_ticks_fail(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        for mode in ("runtime-optimized", "runtime-next-optimized", "native-gpu-optimized"):
            snapshot = drawn_native_gpu_graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            snapshot["graphics_diagnostics"]["canvas_frame_clock"] = False
            with self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)
            snapshot.update(rail_frame_clock_ticks=0, rail_timeline_content_updates=17)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            snapshot["rail_frame_clock_ticks"] = 1
            with self.assertRaisesRegex(InvalidResult, "Nonclock"):
                memory.validate_graphics(snapshot, mode)

    def test_new_mode_flags_and_counter_schema_are_required(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        for mode in memory.NEXT_RUNTIME_MODES:
            snapshot = drawn_native_gpu_graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            for field in memory.NEXT_RUNTIME_FLAGS:
                for invalid in (None, 0, not snapshot["graphics_diagnostics"][field]):
                    changed = copy.deepcopy(snapshot)
                    if invalid is None:
                        del changed["graphics_diagnostics"][field]
                    else:
                        changed["graphics_diagnostics"][field] = invalid
                    with self.subTest(mode=mode, flag=field, value=invalid), self.assertRaises(InvalidResult):
                        memory.validate_graphics(changed, mode)
            for field in memory.NEXT_RUNTIME_COUNTERS:
                for invalid in (None, True, -1):
                    changed = copy.deepcopy(snapshot)
                    changed[field] = invalid
                    with self.subTest(mode=mode, counter=field, value=invalid), self.assertRaises(InvalidResult):
                        memory.validate_graphics(changed, mode)

    def test_legacy_metadata_may_be_absent_but_new_metadata_is_all_or_none(self):
        from test_memory_diagnostic import native_normal_graphics
        snapshot = native_normal_graphics()
        snapshot["graphics_diagnostics"].update(incremental_history_ordering=True,
            optimized_chart_preparation=True, lifecycle_effects_enabled=True)
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        snapshot["graphics_diagnostics"]["shared_chart_preparation"] = False
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(snapshot, "normal")
        snapshot["graphics_diagnostics"]["stable_decoration_hosts"] = False
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(snapshot, "normal")
        snapshot["graphics_diagnostics"]["unpromised_stream_body_writes"] = False
        snapshot.update(dict.fromkeys(memory.NEXT_RUNTIME_COUNTERS, 0))
        diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), "normal")
        diagnostic.validate_graphics_snapshot(snapshot)
        snapshot["shared_chart_normalization_builds"] = 1
        with self.assertRaisesRegex(InvalidResult, "Nonshared"):
            diagnostic.validate_graphics_snapshot(snapshot)
        snapshot["shared_chart_normalization_builds"] = 0
        for field in memory.NEXT_RUNTIME_FLAGS:
            del snapshot["graphics_diagnostics"][field]
        with self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
            diagnostic.validate_graphics_snapshot(snapshot)


class FootprintParserTests(unittest.TestCase):
    def test_dirty_counts_swapped_once_and_preserves_disjoint_categories(self):
        source = footprint_report()
        original = copy.deepcopy(source)
        parsed = memory.parse_footprint(source, PID)
        self.assertEqual(parsed["physical_footprint_bytes"], 12411)
        self.assertEqual(parsed["groups"]["malloc"]["dirty"], 4096)
        self.assertEqual(parsed["groups"]["malloc"]["swapped"], 1024)
        self.assertEqual(parsed["groups"]["malloc"]["wired"], 8192)
        self.assertEqual(parsed["groups"]["graphics_unmapped"]["reclaimable"], 16384)
        self.assertEqual(parsed["groups"]["other_categories"]["dirty"], 123)
        self.assertEqual(sum(group["dirty"] for group in parsed["groups"].values()), 12411)
        self.assertEqual(parsed["categories"], source["processes"][0]["categories"])
        self.assertEqual(source, original)

    def test_requires_exact_byte_units(self):
        for field, value in (("unit", "pages"), ("unit", "bytes"),
                             ("bytes per unit", 1024), ("bytes per unit", True)):
            with self.subTest(field=field, value=value):
                report = footprint_report()
                report[field] = value
                with self.assertRaises(InvalidResult):
                    memory.parse_footprint(report, PID)

    def test_requires_one_matching_integer_pid(self):
        for value in (PID + 1, str(PID), True):
            with self.subTest(pid=value):
                report = footprint_report()
                report["processes"][0]["pid"] = value
                with self.assertRaises(InvalidResult):
                    memory.parse_footprint(report, PID)
        report = footprint_report()
        report["processes"].append(copy.deepcopy(report["processes"][0]))
        with self.assertRaises(InvalidResult):
            memory.parse_footprint(report, PID)

    def test_errors_warnings_and_missing_status_are_not_success(self):
        for field in ("errors", "warnings"):
            for value in (["permission denied"], None):
                with self.subTest(field=field, value=value):
                    report = footprint_report()
                    report[field] = value
                    with self.assertRaises(InvalidResult):
                        memory.parse_footprint(report, PID)

    def test_missing_or_invalid_category_counter_is_rejected(self):
        for value in (-1, True, 1.5, "4096", float("nan"), float("inf"), None):
            with self.subTest(value=value):
                report = footprint_report()
                report["processes"][0]["categories"]["Malloc Small"]["dirty"] = value
                with self.assertRaises(InvalidResult):
                    memory.parse_footprint(report, PID)
        report = footprint_report()
        del report["processes"][0]["categories"]["Malloc Small"]["regions"]
        with self.assertRaises(InvalidResult):
            memory.parse_footprint(report, PID)

    def test_truncated_category_ledger_and_inconsistent_totals_are_rejected(self):
        for mutation in ("category", "auxiliary", "total", "peak"):
            with self.subTest(mutation=mutation):
                report = footprint_report()
                process = report["processes"][0]
                if mutation == "category":
                    del process["categories"]["Future VM category"]
                elif mutation == "auxiliary":
                    process["auxiliary"]["phys_footprint"] += 1
                elif mutation == "total":
                    report["total footprint"] += 1
                else:
                    process["auxiliary"]["phys_footprint_peak"] = 12410
                with self.assertRaises(InvalidResult):
                    memory.parse_footprint(report, PID)

    def test_probe_rejects_duplicate_json_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "footprint.txt"
            output.write_text("Footprint report\n")
            data = Path(directory) / "footprint.json"
            encoded = json.dumps(footprint_report())
            data.write_text(encoded.replace('"bytes per unit": 1',
                                            '"bytes per unit": 1024, "bytes per unit": 1'))
            with self.assertRaisesRegex(InvalidResult, "Duplicate JSON key"):
                memory.parse_probe("footprint", output, data, PID)


class NativeSizeTests(unittest.TestCase):
    def test_binary_sizes_preserve_rounding_resolution(self):
        self.assertEqual(memory.display_size("1.5M")["bytes_approximate"], 1572864)
        self.assertEqual(memory.display_size("1.5M")["display_resolution_bytes"], 104857.6)
        self.assertFalse(memory.display_size("1.5M")["exact"])
        self.assertEqual(memory.display_size("2352")["bytes_approximate"], 2352)
        self.assertTrue(memory.display_size("2352")["exact"])

    def test_unsupported_units_and_nonfinite_sizes_are_rejected(self):
        for value in ("1MB", "1KiB", "1m", "1P", "1.5", "-1K", "NaN", "inf", "1e3", True):
            with self.subTest(value=value), self.assertRaises(InvalidResult):
                memory.display_size(value)


class NativeIdentityTests(unittest.TestCase):
    def test_primary_pid_cannot_be_satisfied_by_parent_or_duplicate_header(self):
        for parser, text in ((memory.parse_vmmap, vmmap_report()), (memory.parse_heap, heap_report())):
            variants = (text.replace(f"FluxLLMApp [{PID}]", "FluxLLMApp [9999]")
                        .replace("FluxLLMResourceCollector [1233]", f"FluxLLMResourceCollector [{PID}]"),
                        f"Process: OtherApp [{PID}]\n" + text)
            for bad in variants:
                with self.subTest(parser=parser.__name__, bad=bad[:80]), self.assertRaises(InvalidResult):
                    parser(bad, PID)

    def test_native_errors_wrong_tool_and_missing_footprint_are_rejected(self):
        for parser, tool, text in ((memory.parse_vmmap, "vmmap", vmmap_report()),
                                   (memory.parse_heap, "heap", heap_report())):
            variants = ("warning: partial task inspection\n" + text,
                        text + f"\n{tool}: cannot read target task\n",
                        text.replace(f"/usr/bin/{tool}", "/usr/bin/other"),
                        text.replace("Physical footprint:         366.5M\n", ""))
            for bad in variants:
                with self.subTest(parser=parser.__name__, bad=bad[:80]), self.assertRaises(InvalidResult):
                    parser(bad, PID)


class VmmapParserTests(unittest.TestCase):
    def test_region_table_keeps_exact_reserved_annotation_and_separate_totals(self):
        parsed = memory.parse_vmmap(vmmap_report(), PID)
        self.assertEqual([row["name"] for row in parsed["regions"]],
                         ["Malloc Small", "Stack (reserved)", "__FONT_DATA"])
        self.assertEqual(parsed["region_total"]["regions"], 5)
        self.assertEqual(parsed["regions"][0]["swapped"]["bytes_approximate"], 4096)
        self.assertNotEqual(parsed["physical_footprint"]["bytes_approximate"],
                            parsed["region_total"]["dirty"]["bytes_approximate"])

    def test_truncation_count_mismatch_unknown_units_and_annotations_are_rejected(self):
        text = vmmap_report()
        variants = (text.split("TOTAL                            ")[0],
                    text.replace("0K 5\n", "0K 6\n"),
                    text.replace("32K 16K", "32MB 16K", 1),
                    text.replace("reserved VM address space (unallocated)",
                                 "reserved VM address space (allocated)"),
                    text.replace("see MALLOC ZONE table below", "unrecognized annotation"))
        for bad in variants:
            with self.subTest(bad=bad[-120:]), self.assertRaises(InvalidResult):
                memory.parse_vmmap(bad, PID)


class HeapParserTests(unittest.TestCase):
    def test_duplicate_blank_long_and_untyped_descriptions_keep_all_allocations(self):
        parsed = memory.parse_heap(heap_report(), PID)
        self.assertEqual(parsed["allocation_count"], 9)
        self.assertEqual(parsed["allocated_bytes"], 1312)
        rows = parsed["allocations"]
        self.assertEqual(len(rows), 6)
        self.assertEqual(sum(row["bytes"] for row in rows if row["description"].startswith("NSDictionary")), 128)
        self.assertEqual(rows[2]["description"], "Swift   SwiftUICore")
        self.assertEqual(rows[3]["description"], LONG_DESCRIPTION)
        self.assertEqual(parsed["groups"]["ui_type_references"]["bytes"], 112)
        self.assertEqual(parsed["groups"]["app_type_references"]["bytes"], 1024)
        self.assertEqual(parsed["groups"]["non_object"]["bytes"], 16)
        self.assertEqual(sum(group["bytes"] for group in parsed["groups"].values()), 1312)

    def test_truncation_count_byte_mismatch_and_zone_pid_are_rejected(self):
        text = heap_report()
        variants = (text.rsplit("       1         32", 1)[0],
                    text.replace("9 nodes (1312 bytes)", "10 nodes (1312 bytes)"),
                    text.replace("9 nodes (1312 bytes)", "9 nodes (1313 bytes)"),
                    text.replace(f"Process {PID}: 6 zones", "Process 9999: 6 zones"),
                    text.replace("       1       1024", "       1       1K"),
                    text + "unrecognized trailer\n")
        for bad in variants:
            with self.subTest(bad=bad[-100:]), self.assertRaises(InvalidResult):
                memory.parse_heap(bad, PID)


if __name__ == "__main__":
    unittest.main()
