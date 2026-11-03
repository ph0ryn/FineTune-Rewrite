"""Independent mutation tests for the migration gate; no original app or settings are loaded."""

import contextlib
import copy
import io
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "auditUpstreamTests.py"
spec = importlib.util.spec_from_file_location("migration_audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class MigrationAuditTests(unittest.TestCase):
    source = '''import Testing
@testable import FineTune
@Suite("Sample")
struct Sample {
    @Test("Two values", arguments: [1, 2])
    func values(_ value: Int) {
        let label = "A B"
        #expect(value < 10)
        #expect(label == "A B")
    }
}
'''
    path = "Tests/UpstreamCompatibilityTests/Sample.swift"
    source_id = "FineTuneTests/Sample.swift::Sample.values"
    destination_id = path + "::Sample.values"

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.file = self.root / self.path
        self.file.parent.mkdir(parents=True)
        self.write(self.source)
        method = audit.scan_swift(self.source, self.path)[self.destination_id]
        self.manifest = {
            "schema_version": 1,
            "upstream": {
                "repository": "https://github.com/ronitsingh10/FineTune",
                "revision": audit.UPSTREAM_REVISION,
                "source_files": 1,
                "declarations": 1,
                "invocations": 2,
            },
            "reviews": {
                "sample": {
                    "author": "implementation-author",
                    "reviewer": "independent-reviewer",
                    "status": "approved",
                    "evidence": "Independent synthetic fixture review",
                }
            },
            "upstream_files": [{"path": "FineTuneTests/Sample.swift", "sha256": "0" * 64}],
            "files": [{
                "derived_from": ["FineTuneTests/Sample.swift"],
                "destination": self.path,
                "tokens_sha256": audit.fingerprint_file(self.source),
                "review": "sample",
            }],
            "tests": [{
                "id": self.source_id,
                "source_line": 5,
                "classification": "A",
                "original_invocations": 2,
                "baseline": method["fingerprints"],
                "destinations": [{
                    "id": self.destination_id,
                    "invocations": 2,
                    "fingerprints": method["fingerprints"],
                }],
                "adaptation": "No semantic changes in this independently authored fixture.",
                "review": "sample",
            }],
            "additional_tests": [],
            "fixtures": [],
        }

    def write(self, source):
        header = "// SPDX-License-Identifier: GPL-3.0-only\n// Upstream revision: " + audit.UPSTREAM_REVISION + "\n"
        self.file.write_text(header + source)

    def errors(self):
        return audit.audit_static(self.root, self.manifest)[0]

    def test_unchanged_fixture_passes_static_gate(self):
        self.assertEqual(self.errors(), [])

    def test_pure_formatter_indentation_passes(self):
        self.write(self.source.replace("    ", "  "))
        self.assertEqual(self.errors(), [])

    def test_multiline_string_formatter_indent_preserves_fingerprint(self):
        first = '''@Test func input() { let json = """
            {"label": "A B"}
            """
            #expect(json.contains("A B"))
        }'''
        second = '''@Test func input() { let json = """
  {"label": "A B"}
  """
  #expect(json.contains("A B"))
}'''
        self.assertEqual(audit.fingerprint_file(first), audit.fingerprint_file(second))
        self.assertNotEqual(audit.fingerprint_file(first), audit.fingerprint_file(first.replace("A B", "AB")))

    def test_string_literal_spaces_are_not_erased(self):
        self.write(self.source.replace('"A B"', '"AB"'))
        self.assertTrue(self.errors())

    def test_weakened_numeric_expectation_fails(self):
        self.write(self.source.replace("value < 10", "value < 100"))
        self.assertTrue(self.errors())

    def test_removed_parameter_fails_even_when_method_count_matches(self):
        self.write(self.source.replace("arguments: [1, 2]", "arguments: [1]"))
        self.assertTrue(self.errors())

    def test_deleted_declaration_fails(self):
        self.write("import Testing\n")
        self.assertTrue(self.errors())

    def test_helper_change_fails_file_fingerprint(self):
        self.write(self.source + "\nfunc helper() -> Int { 9 }\n")
        self.assertTrue(self.errors())

    def test_disabled_or_conditionally_excluded_tests_fail(self):
        self.write(self.source.replace('"Two values",', '"Two values", .disabled(),'))
        self.assertTrue(self.errors())
        self.write("#if false\n" + self.source + "#endif\n")
        self.assertTrue(self.errors())

    def test_known_issue_wrapper_fails(self):
        self.write(self.source.replace("let label", "withKnownIssue { }\n        let label"))
        self.assertTrue(self.errors())

    def test_pending_and_self_review_are_not_approval(self):
        self.manifest["reviews"]["sample"]["status"] = "pending"
        self.assertTrue(self.errors())
        self.manifest["reviews"]["sample"]["status"] = "approved"
        self.manifest["reviews"]["sample"]["reviewer"] = "implementation-author"
        self.assertTrue(self.errors())

    def test_nonportable_exclusion_requires_reason_and_real_replacement(self):
        entry = self.manifest["tests"][0]
        entry["classification"] = "C"
        entry["adaptation"] = ""
        entry["destinations"] = []
        self.assertTrue(self.errors())

    def test_reviewed_many_to_many_unit_consolidation_does_not_require_old_shape_or_count(self):
        unit_path = "Tests/UpstreamCompatibilityTests/FocusedUnits.swift"
        unit_source = '''import Testing
@Suite struct FocusedUnits {
  @Test func allScenarios() {
    for value in [1, 2] { #expect(value < 10) }
    #expect("A B".contains(" "))
  }
}
'''
        unit_id = unit_path + "::FocusedUnits.allScenarios"
        unit_method = audit.scan_swift(unit_source, unit_path)[unit_id]
        self.write("import Testing\n")
        unit_file = self.root / unit_path
        unit_file.write_text("// SPDX-License-Identifier: GPL-3.0-only\n// " + audit.UPSTREAM_REVISION + "\n" + unit_source)
        self.manifest["files"][0]["tokens_sha256"] = audit.fingerprint_file("import Testing\n")
        self.manifest["files"].append({
            "derived_from": ["FineTuneTests/Sample.swift"], "destination": unit_path,
            "tokens_sha256": audit.fingerprint_file(unit_source), "review": "sample",
        })
        first = self.manifest["tests"][0]
        first["classification"] = "B"
        first["adaptation"] = "Input cases move into a focused unit loop; the label invariant is checked in that same unit."
        first["destinations"] = [{"id": unit_id, "invocations": 1, "fingerprints": unit_method["fingerprints"]}]
        second = copy.deepcopy(first)
        second["id"] = "FineTuneTests/Sample.swift::Sample.labelInvariant"
        second["original_invocations"] = 1
        self.manifest["tests"].append(second)
        self.manifest["upstream"]["declarations"] = 2
        self.manifest["upstream"]["invocations"] = 3
        errors, expected = audit.audit_static(self.root, self.manifest)
        self.assertEqual(errors, [])
        self.assertEqual(expected, {unit_id: 1})

    def test_explicit_optional_hardware_evidence_is_not_a_mandatory_CI_invocation(self):
        entry = self.manifest["tests"][0]
        entry["optional_reason"] = "Hardware availability is checked separately, not a CI prerequisite."
        entry["destinations"][0]["execution"] = "optional-hardware"
        errors, expected = audit.audit_static(self.root, self.manifest)
        self.assertEqual(errors, [])
        self.assertEqual(expected, {})
        errors, expected = audit.audit_static(self.root, self.manifest, include_optional=True)
        self.assertEqual(errors, [])
        self.assertEqual(expected, {self.destination_id: 2})

    def test_before_run_snapshot_resets_old_events_and_detects_changed_compiled_source(self):
        events = self.root / "artifacts" / "events.jsonl"
        events.parent.mkdir()
        events.write_text("old evidence must not survive\n")
        snapshot_file = self.root / "artifacts" / "source.json"
        with contextlib.redirect_stdout(io.StringIO()):
            result = audit.main(["--root", str(self.root), "--capture-snapshot", str(snapshot_file), "--events", str(events)])
        self.assertEqual(result, 0)
        self.assertEqual(events.read_text(), "")
        snapshot = json.loads(snapshot_file.read_text())
        events.write_text("\n".join(json.dumps(record) for record in self.event_records()) + "\n")
        self.assertEqual(audit.snapshot_errors(self.root, snapshot, [events]), [])
        self.write(self.source.replace("value < 10", "value < 100"))
        self.assertTrue(audit.snapshot_errors(self.root, snapshot, [events]))

    def test_snapshot_covers_other_compiled_tools_and_resources_not_review_metadata(self):
        probe = self.root / "Tools/AudioProbe/main.swift"
        probe.parent.mkdir(parents=True)
        probe.write_text('print("list")\n')
        fixture = probe.parent / "Fixtures/devices.txt"
        fixture.parent.mkdir()
        fixture.write_text('device=42\n')
        metadata = self.root / "Tools/DSPTests/adaptations.json"
        metadata.parent.mkdir(parents=True)
        metadata.write_text('{"review": "pending"}\n')
        recipes = {
            "Justfile": "test-native:\n    clang++ -O0 actual.cpp\n",
            "scripts/testNativeHAL.py": 'SOURCES = ["actual.cpp"]\n',
        }
        for path, content in recipes.items():
            recipe = self.root / path
            recipe.parent.mkdir(parents=True, exist_ok=True)
            recipe.write_text(content)
        before = audit.source_snapshot(self.root)
        self.assertIn("Tools/AudioProbe/main.swift", before["files"])
        self.assertIn("Tools/AudioProbe/Fixtures/devices.txt", before["files"])
        for path in recipes:
            self.assertIn(path, before["files"])
        metadata.write_text('{"review": "approved"}\n')
        self.assertEqual(audit.source_snapshot(self.root)["sha256"], before["sha256"])
        probe.write_text('print("describe")\n')
        changed_source = audit.source_snapshot(self.root)
        self.assertNotEqual(changed_source["sha256"], before["sha256"])
        fixture.write_text('device=43\n')
        self.assertNotEqual(audit.source_snapshot(self.root)["sha256"], changed_source["sha256"])
        for path, content in recipes.items():
            with self.subTest(recipe=path):
                prepared = audit.source_snapshot(self.root)
                self.assertEqual(audit.snapshot_errors(self.root, prepared, []), [])
                (self.root / path).write_text(content + "# compile recipe changed\n")
                self.assertNotEqual(audit.source_snapshot(self.root)["sha256"], prepared["sha256"])
                self.assertIn("Compile input snapshot changed during/after this test run",
                              audit.snapshot_errors(self.root, prepared, []))

    def test_stale_event_artifact_is_not_current_source_runtime_evidence(self):
        events = self.root / "events.jsonl"
        events.write_text("{}\n")
        snapshot = audit.source_snapshot(self.root)
        snapshot["prepared_events"] = [str(events.resolve())]
        snapshot["captured_at_ns"] = events.stat().st_mtime_ns + 1
        self.assertTrue(audit.snapshot_errors(self.root, snapshot, [events]))

    def test_capture_refuses_to_truncate_source_tree_paths(self):
        events = self.root / "Tests" / "bad.jsonl"
        with contextlib.redirect_stdout(io.StringIO()):
            result = audit.main(["--root", str(self.root), "--capture-snapshot", str(self.root / "snapshot.json"), "--events", str(events)])
        self.assertEqual(result, 1)
        self.assertFalse(events.exists())

    def make_cpp_guarantee(self):
        native_path = "Tools/DSPTests/CompatibilityTests.cpp"
        native_file = self.root / native_path
        native_file.parent.mkdir(parents=True)
        native_source = '// SPDX-License-Identifier: GPL-3.0-only\n// ' + audit.UPSTREAM_REVISION + '\n#include <cassert>\n#include <string>\nvoid values() { assert(1 < 10 && 2 < 10); assert(std::string("A B").find(" ") != std::string::npos); }\n'
        native_file.write_text(native_source)
        self.write("import Testing\n")
        self.manifest["files"][0]["tokens_sha256"] = audit.fingerprint_file("import Testing\n")
        self.manifest["native_files"] = [{
            "destination": native_path, "derived_from": ["FineTuneTests/Sample.swift"],
            "sha256": hashlib.sha256(native_source.encode()).hexdigest(), "review": "sample",
        }]
        entry = self.manifest["tests"][0]
        entry["classification"] = "B"
        entry["adaptation"] = "The same finite scalar inputs are directly checked in the C++ kernel unit."
        entry["destinations"] = [{"kind": "cpp", "id": native_path + "::values", "invocations": 1,
                                   "guarantee": "Inputs 1 and 2 remain below 10; exact scalar comparison."}]
        return native_path + "::values"

    def test_cpp_unit_replaces_swift_shape_with_reviewed_guarantee_mapping(self):
        identifier = self.make_cpp_guarantee()
        errors, expected_swift = audit.audit_static(self.root, self.manifest)
        self.assertEqual(errors, [])
        self.assertEqual(expected_swift, {})
        self.assertEqual(audit.cpp_expectations(self.manifest), {identifier: 1})

    def test_optional_cpp_hardware_guarantees_require_explicit_inclusion_and_reason(self):
        identifier = self.make_cpp_guarantee()
        entry = self.manifest["tests"][0]
        entry["optional_reason"] = "External-device fixture is only executed by a separate explicit runner."
        entry["destinations"][0]["execution"] = "optional-hardware"
        self.assertEqual(audit.audit_static(self.root, self.manifest)[0], [])
        self.assertEqual(audit.cpp_expectations(self.manifest), {})
        self.assertEqual(audit.cpp_expectations(self.manifest, include_optional=True), {identifier: 1})
        del entry["optional_reason"]
        self.assertTrue(audit.audit_static(self.root, self.manifest)[0])
        entry["destinations"][0]["execution"] = "unknown-policy"
        errors, _ = audit.audit_static(self.root, self.manifest)
        self.assertTrue(any("Unknown execution policy" in error for error in errors))
        entry["destinations"][0]["execution"] = "optional-hardware"
        entry["destinations"][0]["invocations"] = 0
        with self.assertRaises(ValueError):
            audit.cpp_expectations(self.manifest)

    def test_cpp_named_runtime_rows_are_separate_from_swift_declarations(self):
        expected = {"Tools/DSPTests/CompatibilityTests.cpp::response.100Hz": 1,
                    "Tools/DSPTests/CompatibilityTests.cpp::response.1000Hz": 1}
        report = {"schema_version": 1, "complete": True, "cases": [
            {"id": identifier, "status": "passed", "invocations": 1} for identifier in expected]}
        errors, summary = audit.audit_cpp_reports([report], expected)
        self.assertEqual(errors, [])
        self.assertEqual(summary["completed_units"], 2)
        self.assertEqual(summary["completed_invocations"], 2)
        mutations = []
        missing = copy.deepcopy(report); missing["cases"].pop(); mutations.append(missing)
        duplicate = copy.deepcopy(report); duplicate["cases"].append(duplicate["cases"][0]); mutations.append(duplicate)
        failed = copy.deepcopy(report); failed["cases"][0]["status"] = "failed"; mutations.append(failed)
        partial = copy.deepcopy(report); partial["complete"] = False; mutations.append(partial)
        unknown = copy.deepcopy(report); unknown["cases"][0]["id"] = "unlisted"; mutations.append(unknown)
        schema = copy.deepcopy(report); schema["schema_version"] = 2; mutations.append(schema)
        zero = copy.deepcopy(report); zero["cases"][0]["invocations"] = 0; mutations.append(zero)
        bad_case = copy.deepcopy(report); bad_case["cases"][0] = "wrong-record-shape"; mutations.append(bad_case)
        for changed in mutations:
            with self.subTest(report=changed):
                errors, _ = audit.audit_cpp_reports([changed], expected)
                self.assertTrue(errors)

    def test_multiple_cpp_suites_form_one_unique_complete_runtime_set(self):
        expected = {"Tools/DSPTests/main.cpp::scalar": 1, "Tests/NativeStageTests/main.cpp::matrix": 3}
        reports = [{"schema_version": 1, "complete": True, "cases": [
            {"id": identifier, "status": "passed", "invocations": count, "checks": count * 10}]
        } for identifier, count in expected.items()]
        errors, summary = audit.audit_cpp_reports(reports, expected)
        self.assertEqual(errors, [])
        self.assertEqual(summary["completed_units"], 2)
        self.assertEqual(summary["completed_invocations"], 4)
        self.assertTrue(audit.audit_cpp_reports(reports[:1], expected)[0])
        self.assertTrue(audit.audit_cpp_reports(reports + [copy.deepcopy(reports[0])], expected)[0])
        incomplete = copy.deepcopy(reports)
        incomplete[1]["complete"] = False
        self.assertTrue(audit.audit_cpp_reports(incomplete, expected)[0])

    def test_cpp_report_is_freshly_prepared_and_uses_the_same_native_source_snapshot(self):
        artifacts = self.root / "artifacts"
        artifacts.mkdir()
        events = artifacts / "events.jsonl"
        report_file = artifacts / "cpp.json"
        second_report_file = artifacts / "cpp-stages.json"
        report_file.write_text('{"complete": true, "old": true}')
        second_report_file.write_text('{"complete": true, "old": true}')
        native = self.root / "Tools/DSPTests/main.cpp"
        native.parent.mkdir(parents=True)
        native.write_text("int scalarKernel() { return 1; }\n")
        snapshot_file = artifacts / "source.json"
        with contextlib.redirect_stdout(io.StringIO()):
            result = audit.main(["--root", str(self.root), "--capture-snapshot", str(snapshot_file),
                                 "--events", str(events), "--cpp-events", str(report_file),
                                 "--cpp-events", str(second_report_file)])
        self.assertEqual(result, 0)
        self.assertEqual(report_file.read_text(), "")
        self.assertEqual(second_report_file.read_text(), "")
        snapshot = json.loads(snapshot_file.read_text())
        cpp_paths = [report_file, second_report_file]
        self.assertEqual(snapshot["prepared_cpp_events"], sorted(str(path.resolve()) for path in cpp_paths))
        events.write_text("{}\n")
        report_file.write_text('{"schema_version": 1, "complete": true, "cases": []}\n')
        self.assertTrue(audit.snapshot_errors(self.root, snapshot, [events], cpp_paths))
        second_report_file.write_text('{"schema_version": 1, "complete": true, "cases": []}\n')
        self.assertEqual(audit.snapshot_errors(self.root, snapshot, [events], cpp_paths), [])
        self.assertTrue(audit.snapshot_errors(self.root, snapshot, [events], [report_file]))
        (self.root / "README.md").write_text("Review documentation may change after execution.\n")
        (self.root / "Tests/UpstreamCompatibilityTests/migrationManifest.json").write_text("{}\n")
        self.assertEqual(audit.snapshot_errors(self.root, snapshot, [events], cpp_paths), [])
        native.write_text("int scalarKernel() { return 2; }\n")
        self.assertTrue(audit.snapshot_errors(self.root, snapshot, [events], cpp_paths))

    def event_records(self):
        runtime_id = "UpstreamCompatibilityTests.Sample/values(_:) /Sample.swift:5:4"
        descriptor = {
            "kind": "test", "version": 0,
            "payload": {
                "id": runtime_id, "kind": "function", "name": "values(_:)",
                "isParameterized": True,
                "sourceLocation": {"fileID": "UpstreamCompatibilityTests/Sample.swift"},
                "_testCases": [{"id": "case-one"}, {"id": "case-two"}],
            },
        }
        events = [descriptor]
        def event(kind, **fields):
            return {"kind": "event", "version": 0, "payload": {"kind": kind, **fields}}
        events.append(event("runStarted"))
        events.append(event("testStarted", testID=runtime_id))
        for case in ["case-one", "case-two"]:
            events.append(event("testCaseStarted", testID=runtime_id, _testCase={"id": case}))
            events.append(event("testCaseEnded", testID=runtime_id, _testCase={"id": case}))
        events.append(event("testEnded", testID=runtime_id))
        events.append(event("runEnded"))
        return events

    def runtime_errors(self, records):
        return audit.audit_events(records, {self.destination_id: 2})[0]

    def test_parameter_invocations_are_counted_separately_from_declarations(self):
        errors, summary = audit.audit_events(self.event_records(), {self.destination_id: 2})
        self.assertEqual(errors, [])
        self.assertEqual(summary["declarations"], 1)
        self.assertEqual(summary["invocations"], 2)

    def test_missing_parameter_completion_and_duplicate_case_fail(self):
        records = self.event_records()
        del records[6]
        self.assertTrue(self.runtime_errors(records))
        records = self.event_records()
        records.insert(7, copy.deepcopy(records[6]))
        self.assertTrue(self.runtime_errors(records))

    def test_runtime_skip_issue_and_truncated_run_fail(self):
        for kind in ["testSkipped", "issueRecorded", "knownIssueRecorded"]:
            records = self.event_records()
            records.insert(3, {"kind": "event", "version": 0, "payload": {"kind": kind}})
            self.assertTrue(self.runtime_errors(records), kind)
        records = self.event_records()[:-1]
        self.assertTrue(self.runtime_errors(records))

    def test_wrong_schema_and_missing_expected_test_fail(self):
        records = self.event_records()
        records[0]["version"] = 1
        self.assertTrue(self.runtime_errors(records))
        records = self.event_records()[1:]
        self.assertTrue(self.runtime_errors(records))


if __name__ == "__main__":
    unittest.main()
