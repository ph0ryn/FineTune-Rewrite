#!/usr/bin/env python3
"""Fail-closed audit of reviewed upstream test mappings and Swift Testing JSONL v0.

Fingerprints are lexical change detectors, not proofs of B/C semantic equivalence.
The independently recorded review is a separate, mandatory part of the contract.
Only the Python standard library and the project's existing Swift formatter are used.
"""

import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

UPSTREAM_REVISION = "2285279d36d3f8115c1c2d4aecd904f1bdf96a51"
FINGERPRINT_ALGORITHM = "swift-format-lexical-v1"
BASELINE_TOTALS = {"source_files": 54, "declarations": 758, "invocations": 966}
NATIVE_SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".m", ".mm"}


def digest(value):
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


@lru_cache(maxsize=256)
def formatted(source):
    result = subprocess.run(
        ["xcrun", "swift", "format", "format"], input=source, text=True,
        capture_output=True, check=False,
    )
    if result.returncode:
        raise ValueError("Swift formatter rejected source: " + result.stderr.strip())
    return result.stdout


def formatter_version():
    return subprocess.check_output(["xcrun", "swift", "format", "--version"], text=True).strip()


def tokens(source):
    """Small string/comment-aware lexer, checked against every fixed-census test ID.

    Swift format first normalizes incidental multiline-string indentation and layout.
    String contents (including meaningful whitespace) and numeric spellings survive.
    This is deliberately not a type resolver or a complete Swift grammar.
    """
    text = formatted(source)
    result = []
    size = len(text)

    def comment_end(start):
        if text.startswith("//", start):
            end = text.find("\n", start)
            return size if end < 0 else end
        depth, position = 1, start + 2
        while position < size and depth:
            if text.startswith("/*", position):
                depth += 1
                position += 2
            elif text.startswith("*/", position):
                depth -= 1
                position += 2
            else:
                position += 1
        if depth:
            raise ValueError("Unterminated Swift comment")
        return position

    def string_end(start):
        position = start
        while position < size and text[position] == "#":
            position += 1
        hashes = text[start:position]
        if position >= size or text[position] != '"':
            return None
        quotes = '"""' if text.startswith('"""', position) else '"'
        position += len(quotes)
        closing = quotes + hashes
        escape = "\\" + hashes
        while position < size:
            if text.startswith(escape + "(", position):
                position = interpolation_end(position + len(escape) + 1)
            elif text.startswith(escape, position):
                position += len(escape) + 1
            elif text.startswith(closing, position):
                return position + len(closing)
            else:
                position += 1
        raise ValueError("Unterminated Swift string")

    def interpolation_end(position):
        depth = 1
        while position < size:
            if text.startswith("//", position) or text.startswith("/*", position):
                position = comment_end(position)
                continue
            end = string_end(position) if text[position] in '#"' else None
            if end is not None:
                position = end
                continue
            if text[position] == "(":
                depth += 1
            elif text[position] == ")":
                depth -= 1
                if not depth:
                    return position + 1
            position += 1
        raise ValueError("Unterminated Swift interpolation")

    position = 0
    while position < size:
        if text[position].isspace():
            position += 1
            continue
        if text.startswith("//", position) or text.startswith("/*", position):
            position = comment_end(position)
            continue
        end = string_end(position) if text[position] in '#"' else None
        if end is None:
            match = re.match(r"[A-Za-z_][A-Za-z_0-9]*|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|.", text[position:])
            end = position + len(match.group())
        result.append((text[position:end], text.count("\n", 0, position) + 1))
        position = end
    # A final comma in an argument/list has no semantic content. Do not remove any
    # whitespace or punctuation inside a string literal, or commas between inputs.
    return [item for i, item in enumerate(result)
            if not (item[0] == "," and i + 1 < len(result) and result[i + 1][0] in ("]", ")"))]


def token_values(source):
    return [value for value, _ in tokens(source)]


def fingerprint_file(source):
    return digest(token_values(source))


def matching(values):
    pairs, stack = {}, []
    closing = {")": "(", "]": "[", "}": "{"}
    for index, value in enumerate(values):
        if value in ("(", "[", "{"):
            stack.append((value, index))
        elif value in closing:
            if not stack or stack[-1][0] != closing[value]:
                raise ValueError("Unbalanced Swift delimiter")
            _, opening = stack.pop()
            pairs[opening] = index
    if stack:
        raise ValueError("Unclosed Swift delimiter")
    return pairs


def scan_swift(source, path):
    items = tokens(source)
    values = [value for value, _ in items]
    pairs = matching(values)
    types = []
    for index, value in enumerate(values[:-1]):
        if value in ("struct", "class", "enum", "actor", "extension"):
            opening = next((i for i in range(index + 2, len(values)) if values[i] == "{"), None)
            if opening is not None:
                types.append((opening, pairs[opening], values[index + 1]))
    methods = {}
    for index in range(len(values) - 1):
        if values[index:index + 2] != ["@", "Test"]:
            continue
        attr_end = pairs[index + 2] + 1 if values[index + 2:index + 3] == ["("] else index + 2
        function = next((i for i in range(attr_end, len(values)) if values[i] == "func"), None)
        if function is None:
            raise ValueError(f"@Test has no function in {path}")
        name = values[function + 1]
        parameters = next(i for i in range(function + 2, len(values)) if values[i] == "(")
        opening = next(i for i in range(pairs[parameters] + 1, len(values)) if values[i] == "{")
        closing = pairs[opening]
        suite = ".".join(name for start, end, name in types if start < function < end)
        identifier = f"{path}::{suite + '.' if suite else ''}{name}"
        if identifier in methods:
            raise ValueError(f"Duplicate test identity: {identifier}")
        attribute = values[index:attr_end]
        argument_index = next((i for i in range(index + 2, attr_end - 1)
                               if values[i:i + 2] == ["arguments", ":"]), None)
        arguments = []
        count = 1
        if argument_index is not None:
            start = argument_index + 2
            if values[start] == "[":
                end = pairs[start]
                arguments = values[start:end + 1]
                cursor, count = start + 1, 0
                while cursor < end:
                    count += 1
                    while cursor < end and values[cursor] != ",":
                        cursor = pairs[cursor] + 1 if cursor in pairs else cursor + 1
                    cursor += 1
            else:
                # The sole nonliteral collection in the verified fixed census.
                arguments = values[start:attr_end - 1]
                if arguments != ["VolumeHotkeyStep", ".", "allCases"]:
                    raise ValueError(f"Unrecognized parameter collection in {identifier}: {arguments}")
                count = 4
        assertions = []
        cursor = opening + 1
        while cursor < closing:
            length = 0
            if values[cursor:cursor + 2] in (["#", "expect"], ["#", "require"]):
                length = 2
            elif values[cursor:cursor + 3] == ["Issue", ".", "record"]:
                length = 3
            if length and values[cursor + length:cursor + length + 1] == ["("]:
                end = pairs[cursor + length] + 1
                if values[end:end + 1] == ["{"]:
                    end = pairs[end] + 1
                assertions.append(values[cursor:end])
                cursor = end
            else:
                cursor += 1
        methods[identifier] = {
            "path": path, "suite": suite, "name": name, "line": items[index][1],
            "invocations": count,
            "fingerprints": {
                "body": digest(values[opening:closing + 1]),
                "arguments": digest(arguments),
                "assertions": digest(assertions),
                "attribute": digest(attribute),
            },
        }
    return methods


def forbidden(source):
    values = token_values(source)
    issues = []
    if "withKnownIssue" in values:
        issues.append("known-issue wrapper")
    for index, value in enumerate(values[:-1]):
        if value == "#" and values[index + 1] in ("if", "elseif", "else", "endif"):
            issues.append("conditional compilation in test source")
        if values[index:index + 2] in (["@", "Test"], ["@", "Suite"]):
            if values[index + 2:index + 3] == ["("]:
                end = matching(values)[index + 2]
                if any(item in ("disabled", "enabled") for item in values[index + 3:end]):
                    issues.append("conditional/disabled test or suite")
    return issues


def audit_static(root, manifest, include_optional=False):
    errors, expected = [], {}
    if manifest.get("schema_version") != 1:
        errors.append("Unsupported migration manifest schema")
    upstream = manifest.get("upstream", {})
    if upstream.get("revision") != UPSTREAM_REVISION:
        errors.append("Upstream revision differs from fixed baseline")
    records = manifest.get("tests", [])
    ids = [entry["id"] for entry in records]
    if len(set(ids)) != len(ids):
        errors.append("Duplicate upstream test IDs")
    if len(ids) != upstream.get("declarations"):
        errors.append("Upstream declaration denominator changed")
    if sum(entry["original_invocations"] for entry in records) != upstream.get("invocations"):
        errors.append("Upstream invocation denominator changed")
    files = manifest.get("files", [])
    source_paths = [entry["path"] for entry in manifest.get("upstream_files", [])]
    if len(set(source_paths)) != len(source_paths) or len(source_paths) != upstream.get("source_files"):
        errors.append("Upstream source-file denominator changed")
    for identifier in ids:
        if identifier.split("::", 1)[0] not in source_paths:
            errors.append(f"Unknown upstream source identity: {identifier}")
    review_errors = set()

    def review(key):
        item = manifest.get("reviews", {}).get(key, {})
        if item.get("status") != "approved" or not item.get("evidence") or not item.get("reviewer"):
            review_errors.add(f"Independent review pending/missing: {key}")
        elif not item.get("author") or item["author"] == item["reviewer"]:
            review_errors.add(f"Self-review is not independent approval: {key}")

    notice = manifest.get("license_notice", {})
    notice_file = root / notice.get("path", "__missing_notice__")
    license_file = root / notice.get("license_path", "__missing_license__")
    directory_provenance = False
    if notice_file.is_file() and license_file.is_file():
        notice_text = notice_file.read_text()
        directory_provenance = (
            UPSTREAM_REVISION in notice_text and "GPL" in notice_text
            and "ronitsingh10/FineTune" in notice_text
            and hashlib.sha256(license_file.read_bytes()).hexdigest() == notice.get("license_sha256")
        )
    native_paths = set()
    for entry in manifest.get("native_files", []):
        path = entry["destination"]
        file = root / path
        native_paths.add(path)
        review(entry.get("review"))
        if not file.is_file():
            errors.append(f"Missing native unit source: {path}")
        elif hashlib.sha256(file.read_bytes()).hexdigest() != entry.get("sha256"):
            errors.append(f"Unreviewed native unit source change: {path}")
        elif entry.get("derived_from") and not directory_provenance:
            source = file.read_text()
            if "SPDX-License-Identifier: GPL-3.0-only" not in source or UPSTREAM_REVISION not in source:
                errors.append(f"Missing native GPL/fixed-source provenance: {path}")
    # Source/helper registration is separate from the explicit named CPP destinations below.
    for directory in ("Tests", "Tools"):
        for file in sorted((root / directory).rglob("*")):
            relative = file.relative_to(root)
            if not file.is_file() or file.suffix not in NATIVE_SOURCE_SUFFIXES or any(
                part in (".build", "__pycache__") for part in relative.parts
            ):
                continue
            path = relative.as_posix()
            if path not in native_paths:
                errors.append(f"Unlisted native test/helper source: {path}")
    actual = {}
    accounted_paths = set()
    for entry in files + manifest.get("support_files", []):
        path = entry["destination"]
        if path in accounted_paths:
            errors.append(f"Duplicate destination-file record: {path}")
            continue
        accounted_paths.add(path)
        review(entry.get("review"))
        file = root / path
        if not file.is_file():
            errors.append(f"Missing destination file: {path}")
            continue
        source = file.read_text()
        try:
            if fingerprint_file(source) != entry.get("tokens_sha256"):
                errors.append(f"Unreviewed file/helper/input change: {path}")
            errors.extend(f"{reason}: {path}" for reason in forbidden(source))
            actual.update(scan_swift(source, path))
        except ValueError as error:
            errors.append(f"Cannot inspect {path}: {error}")
        if entry.get("derived_from"):
            file_provenance = (
                ("SPDX-License-Identifier: GPL-3.0-only" in source or "SPDX-License-Identifier: GPL-3.0-or-later" in source)
                and UPSTREAM_REVISION in source
            )
            if not file_provenance and not directory_provenance:
                errors.append(f"Missing GPL/fixed-source provenance: {path}")
    for file in sorted((root / "Tests").rglob("*.swift")):
        path = file.relative_to(root).as_posix()
        if path not in accounted_paths:
            errors.append(f"Unlisted test/support source: {path}")

    mapped = set()
    for entry in records + manifest.get("additional_tests", []):
        classification = entry.get("classification", "D" if entry in manifest.get("additional_tests", []) else None)
        if classification not in ("A", "B", "C", "D"):
            errors.append(f"Unclassified test: {entry['id']}")
        review(entry.get("review"))
        if not entry.get("adaptation"):
            errors.append(f"Missing adaptation/replacement rationale: {entry['id']}")
        destinations = entry.get("destinations", [])
        if not destinations:
            errors.append(f"No executable destination/replacement: {entry['id']}")
        if classification == "C" and not entry.get("nonportable_reason"):
            errors.append(f"No nonportable structural reason: {entry['id']}")
        if classification == "A" and sum(item["invocations"] for item in destinations) != entry["original_invocations"]:
            errors.append(f"A input case reduction/change: {entry['id']}")
        for destination in destinations:
            identifier = destination["id"]
            kind = destination.get("kind", "swift")
            execution = destination.get("execution", "required")
            if execution not in ("required", "optional-hardware"):
                errors.append(f"Unknown execution policy: {identifier}")
            if execution == "optional-hardware" and not entry.get("optional_reason"):
                errors.append(f"Optional hardware coverage has no explicit reason: {identifier}")
            if kind == "cpp":
                if identifier.split("::", 1)[0] not in native_paths:
                    errors.append(f"Unlisted native destination source: {identifier}")
                if not destination.get("guarantee"):
                    errors.append(f"Native unit input/tolerance guarantee not recorded: {identifier}")
                continue
            if kind != "swift":
                errors.append(f"Unknown destination kind: {identifier}")
                continue
            method = actual.get(identifier)
            mapped.add(identifier)
            if execution == "required" or include_optional:
                if identifier in expected and expected[identifier] != destination["invocations"]:
                    errors.append(f"Conflicting destination invocation count: {identifier}")
                expected[identifier] = destination["invocations"]
            if method is None:
                errors.append(f"Missing mapped test: {identifier}")
                continue
            if method["invocations"] != destination["invocations"]:
                errors.append(f"Parameter input count changed: {identifier}")
            reviewed_fingerprints = dict(entry.get("baseline", {}))
            reviewed_fingerprints.update(destination.get("fingerprints", {}))
            if method["fingerprints"] != reviewed_fingerprints:
                errors.append(f"Unreviewed input/body/assertion change: {identifier}")
            if classification == "A":
                changes = entry.get("allowed_changes", [])
                for kind, original in entry.get("baseline", {}).items():
                    if method["fingerprints"].get(kind) != original and kind not in changes:
                        errors.append(f"Unexplained A {kind} adaptation: {identifier}")
    for identifier in actual.keys() - mapped:
        errors.append(f"Unlisted D/new test declaration: {identifier}")
    for entry in manifest.get("fixtures", []):
        file = root / entry["destination"]
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != entry["sha256"]:
            errors.append(f"Missing/changed original fixture: {entry['destination']}")
    errors.extend(sorted(review_errors))
    return errors, expected


def event_identifier(payload):
    file_id = payload["sourceLocation"]["fileID"]
    module, _, relative = file_id.partition("/")
    path = f"Tests/{module}/{relative}"
    owner = payload["id"].split("/", 1)[0]
    suite = owner[len(module) + 1:] if owner.startswith(module + ".") else ""
    name = payload["name"].split("(", 1)[0]
    return f"{path}::{suite + '.' if suite else ''}{name}"


def audit_events(records, expected):
    errors, descriptors = [], {}
    starts, ends = Counter(), Counter()
    case_starts, case_ends = Counter(), Counter()
    run_starts = run_ends = 0
    for record in records:
        if record.get("version") != 0:
            errors.append("Unsupported Swift Testing event schema (expected v0)")
            continue
        payload = record.get("payload", {})
        if record.get("kind") == "test" and payload.get("kind") == "function":
            identifier = payload["id"]
            if identifier in descriptors:
                errors.append(f"Duplicate runtime descriptor: {identifier}")
            descriptors[identifier] = payload
        elif record.get("kind") == "event":
            kind, identifier = payload.get("kind"), payload.get("testID")
            if kind == "runStarted":
                run_starts += 1
            elif kind == "runEnded":
                run_ends += 1
            elif kind == "testStarted":
                starts[identifier] += 1
            elif kind == "testEnded":
                ends[identifier] += 1
            elif kind in ("testCaseStarted", "testCaseEnded"):
                case = payload.get("_testCase", {}).get("id")
                if case is None:
                    errors.append(f"Missing parameter case identity: {identifier}")
                (case_starts if kind == "testCaseStarted" else case_ends)[(identifier, case)] += 1
            elif kind in ("testSkipped", "testCaseSkipped", "issueRecorded", "knownIssueRecorded"):
                errors.append(f"Runtime skip/issue is not a pass: {kind} {identifier}")
            if any(message.get("symbol") in ("fail", "error") for message in payload.get("messages", [])):
                errors.append(f"Runtime failure message: {identifier or kind}")
    if not run_starts or run_starts != run_ends:
        errors.append(f"Missing/truncated test run: started={run_starts}, ended={run_ends}")
    found, invocations = set(), 0
    for runtime_id, payload in descriptors.items():
        try:
            identifier = event_identifier(payload)
        except (KeyError, ValueError) as error:
            errors.append(f"Invalid runtime function identity: {error}")
            continue
        if identifier in found:
            errors.append(f"Runtime test executed more than once: {identifier}")
        found.add(identifier)
        if identifier not in expected:
            errors.append(f"Unlisted runtime test: {identifier}")
        if starts[runtime_id] != 1 or ends[runtime_id] != 1:
            errors.append(f"Missing/duplicate function execution: {identifier}")
        if payload.get("isParameterized"):
            cases = [case["id"] for case in payload.get("_testCases", [])]
            if len(set(cases)) != len(cases):
                errors.append(f"Duplicate declared parameter identities: {identifier}")
            if len(cases) != expected.get(identifier):
                errors.append(f"Runtime parameter case count mismatch: {identifier}")
            for case in cases:
                if case_starts[(runtime_id, case)] != 1 or case_ends[(runtime_id, case)] != 1:
                    errors.append(f"Missing/duplicate parameter execution: {identifier} {case}")
            observed = {case for test, case in case_starts.keys() | case_ends.keys() if test == runtime_id}
            if observed != set(cases):
                errors.append(f"Undeclared parameter execution: {identifier}")
            invocations += sum(case_ends[(runtime_id, case)] for case in cases)
        else:
            if expected.get(identifier) != 1:
                errors.append(f"Expected parameter matrix became singleton: {identifier}")
            invocations += ends[runtime_id]
    errors.extend(f"Expected test absent from runtime: {identifier}" for identifier in sorted(expected.keys() - found))
    return errors, {"declarations": len(found), "invocations": invocations,
                    "runs_started": run_starts, "runs_ended": run_ends}


def cpp_expectations(manifest, include_optional=False):
    expected = {}
    for entry in manifest.get("tests", []) + manifest.get("additional_tests", []):
        for destination in entry.get("destinations", []):
            if destination.get("kind") != "cpp":
                continue
            identifier, count = destination["id"], destination["invocations"]
            if not isinstance(count, int) or isinstance(count, bool) or count < 1:
                raise ValueError(f"Invalid native unit invocation count: {identifier}")
            if destination.get("execution") == "optional-hardware" and not include_optional:
                continue
            if identifier in expected and expected[identifier] != count:
                raise ValueError(f"Conflicting native unit invocation count: {identifier}")
            expected[identifier] = count
    return expected


def audit_cpp_reports(reports, expected):
    errors = []
    counts = Counter()
    for report in reports:
        if not isinstance(report, dict) or report.get("schema_version") != 1 or report.get("complete") is not True or not isinstance(report.get("cases"), list):
            errors.append("Incomplete/unsupported native named-unit report")
            continue
        for case in report["cases"]:
            if not isinstance(case, dict):
                errors.append("Unsupported native runtime case record")
                continue
            identifier = case.get("id")
            if identifier not in expected:
                errors.append(f"Unlisted native runtime unit: {identifier}")
            count = case.get("invocations")
            if not isinstance(count, int) or isinstance(count, bool) or count < 1:
                errors.append(f"Invalid native runtime count: {identifier}")
                continue
            if identifier in counts:
                errors.append(f"Duplicate native runtime unit: {identifier}")
            counts[identifier] += count
            if case.get("status") != "passed":
                errors.append(f"Failed native runtime unit: {identifier}")
    for identifier, count in expected.items():
        if counts[identifier] != count:
            errors.append(f"Native runtime unit count mismatch: {identifier}: {counts[identifier]} != {count}")
    return errors, {"reports": len(reports), "completed_units": len(counts), "completed_invocations": sum(counts.values())}


def source_snapshot(root):
    """Hash compile inputs, not mutable review/docs metadata or build artifacts."""
    root = root.resolve()
    files = {}
    suffixes = NATIVE_SOURCE_SUFFIXES | {".swift", ".json", ".png", ".jpg", ".icns",
                                         ".plist", ".entitlements", ".xcconfig", ".modulemap"}
    for directory in ("Sources", "App", "Tests", "Tools"):
        base = root / directory
        if not base.is_dir():
            continue
        for file in sorted(base.rglob("*")):
            relative = file.relative_to(root)
            is_resource = any(part in ("Fixtures", "Resources") or part.endswith(".xcassets") for part in relative.parts)
            if not file.is_file() or (file.suffix not in suffixes and not is_resource) or any(part in (".build", "__pycache__") for part in relative.parts):
                continue
            if relative.as_posix() in (
                "Tests/UpstreamCompatibilityTests/migrationManifest.json",
                "Tools/DSPTests/adaptations.json",
            ):
                continue
            files[relative.as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
    for path in ("Package.swift", "Package.resolved", "FineTune.xcodeproj/project.pbxproj",
                 "Config/AppInfo.plist", "Justfile", "scripts/buildApp.sh", "scripts/testNativeHAL.py"):
        file = root / path
        if file.is_file():
            files[path] = hashlib.sha256(file.read_bytes()).hexdigest()
    return {"schema_version": 1, "root": str(root), "sha256": digest(sorted(files.items())), "files": files}


def snapshot_errors(root, snapshot, event_paths, cpp_paths=()):
    root = root.resolve()
    errors = []
    current = source_snapshot(root)
    if snapshot.get("schema_version") != 1 or snapshot.get("sha256") != current["sha256"]:
        errors.append("Compile input snapshot changed during/after this test run")
    if snapshot.get("root") != str(root):
        errors.append("Run snapshot belongs to a different source root")
    expected_paths = sorted(snapshot.get("prepared_events", []))
    if sorted(str(path.resolve()) for path in event_paths) != expected_paths:
        errors.append("Runtime event paths do not match the freshly prepared run")
    if sorted(str(path.resolve()) for path in cpp_paths) != sorted(snapshot.get("prepared_cpp_events", [])):
        errors.append("Native report paths do not match the freshly prepared run")
    for path in list(event_paths) + list(cpp_paths):
        if not path.is_file() or path.stat().st_mtime_ns < snapshot.get("captured_at_ns", 0):
            errors.append(f"Missing/stale runtime event file: {path}")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--manifest", type=Path, default=Path("Tests/UpstreamCompatibilityTests/migrationManifest.json"))
    parser.add_argument("--events", type=Path, action="append", default=[], help="JSONL v0; repeat for distinct test products, not debug+release together")
    parser.add_argument("--cpp-events", type=Path, action="append", default=[], help="Repeat for distinct native suites: version-1 complete named-unit JSON, not debug+release together")
    parser.add_argument("--static-only", action="store_true", help="Review/static check only, NOT a complete runtime gate")
    parser.add_argument("--include-optional-hardware", action="store_true", help="Explicitly require separately recorded optional hardware tests in this run")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--capture-snapshot", type=Path, help="Prepare a run: hash compile inputs and reset every explicitly supplied --events/--cpp-events artifact")
    parser.add_argument("--source-snapshot", type=Path, help="Before-run source snapshot required for a complete runtime gate")
    options = parser.parse_args(argv)
    root = options.root.resolve()
    manifest_path = options.manifest if options.manifest.is_absolute() else root / options.manifest
    try:
        if options.capture_snapshot:
            if not options.events and not options.cpp_events:
                raise ValueError("Preparing a run requires explicit event/report artifact paths")
            for paths, suffix in ((options.events, ".jsonl"), (options.cpp_events, ".json")):
                for path in paths:
                    resolved = path.resolve()
                    if resolved.suffix != suffix or resolved == options.capture_snapshot.resolve():
                        raise ValueError(f"Only a distinct {suffix} report artifact can be reset")
                    if any(resolved.is_relative_to(root / directory) for directory in ("Sources", "App", "Tests", "Tools")):
                        raise ValueError("Refusing to overwrite a source-tree path with runtime events")
                    resolved.parent.mkdir(parents=True, exist_ok=True)
                    resolved.write_text("")
            snapshot = source_snapshot(root)
            snapshot["prepared_events"] = sorted(str(path.resolve()) for path in options.events)
            snapshot["prepared_cpp_events"] = sorted(str(path.resolve()) for path in options.cpp_events)
            snapshot["captured_at_ns"] = time.time_ns()
            options.capture_snapshot.parent.mkdir(parents=True, exist_ok=True)
            options.capture_snapshot.write_text(json.dumps(snapshot, indent=2) + "\n")
            print(json.dumps({"status": "captured-not-executed", "sha256": snapshot["sha256"], "files": len(snapshot["files"])}))
            return 0
        manifest = json.loads(manifest_path.read_text())
        errors, expected = audit_static(root, manifest, options.include_optional_hardware)
        for key, value in BASELINE_TOTALS.items():
            if manifest.get("upstream", {}).get(key) != value:
                errors.append(f"Fixed baseline {key} must remain {value}")
        expected_cpp = cpp_expectations(manifest, options.include_optional_hardware)
        runtime, cpp_runtime, run_source_sha256 = None, None, None
        if options.events or options.cpp_events:
            if options.source_snapshot:
                snapshot = json.loads(options.source_snapshot.read_text())
                run_source_sha256 = snapshot.get("sha256")
                errors.extend(snapshot_errors(root, snapshot, options.events, options.cpp_events))
            elif not options.static_only:
                errors.append("Before-run source snapshot required for current-source runtime evidence")
        elif not options.static_only:
            errors.append("Runtime event/report evidence required (or explicitly select --static-only)")
        if options.events:
            records = []
            for path in options.events:
                records.extend(json.loads(line) for line in path.read_text().splitlines() if line.strip())
            runtime_errors, runtime = audit_events(records, expected)
            errors.extend(runtime_errors)
        elif expected and not options.static_only:
            errors.append("Swift runtime event evidence missing")
        if options.cpp_events:
            reports = [json.loads(path.read_text()) for path in options.cpp_events]
            cpp_errors, cpp_runtime = audit_cpp_reports(reports, expected_cpp)
            errors.extend(cpp_errors)
        elif expected_cpp and not options.static_only:
            errors.append("Native named-unit runtime evidence missing")
        summary = {
            "status": "fail" if errors else ("static-only" if options.static_only else "pass"),
            "upstream_revision": UPSTREAM_REVISION,
            "classification_counts": dict(Counter(entry.get("classification", "pending") for entry in manifest["tests"])),
            "new_D_declarations": len(manifest.get("additional_tests", [])),
            "expected_destination_declarations": len(expected),
            "expected_destination_invocations": sum(expected.values()),
            "expected_cpp_units": len(expected_cpp),
            "expected_cpp_invocations": sum(expected_cpp.values()),
            "runtime": runtime, "cpp_runtime": cpp_runtime,
            "source_snapshot_sha256": run_source_sha256,
            "run_artifacts": [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                              for path in options.events + options.cpp_events],
            "formatter_version": formatter_version(),
            "fingerprint_algorithm": FINGERPRINT_ALGORITHM, "errors": errors,
        }
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        summary = {"status": "fail", "errors": [str(error)]}
    output = json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    if options.json_output:
        options.json_output.write_text(output)
    print(output, end="")
    return 1 if summary["status"] == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
