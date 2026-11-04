#!/usr/bin/env python3
"""Run the real native C boundary with only the external HAL provider replaced."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


SOURCES = [
    "Sources/AudioDSP/AudioDSP.cpp",
    "Sources/AudioDSP/Filters/Biquad.cpp",
    "Sources/AudioDSP/Filters/AutoEQ.cpp",
    "Sources/AudioDSP/Dynamics/Loudness.cpp",
    "Sources/AudioDSP/Dynamics/ISO226.cpp",
    "Sources/AudioDSP/Dynamics/SoftLimiter.cpp",
    "Sources/AudioDSP/Graph/Pipeline.cpp",
    "Sources/NativeAudio/BiquadBridge.cpp",
    "Sources/NativeAudio/DynamicsBridge.cpp",
    "Sources/NativeAudio/PipelineBridge.cpp",
    "Sources/NativeAudio/Runtime/NativeRuntime.cpp",
    "Tests/NativeHALContractTests/main.cpp",
]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, root, log):
    result = subprocess.run(command, cwd=root, text=True, capture_output=True)
    log.write_text(" ".join(map(str, command)) + "\n" + result.stdout + result.stderr)
    require(result.returncode == 0, f"Command failed ({result.returncode}); see {log}\n{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    scratch = (root / args.scratch_path).resolve()
    directory = scratch / f"native-hal-{args.configuration}"
    directory.mkdir(parents=True, exist_ok=True)
    report = scratch / f"test-native-hal-results-{args.configuration}.json"
    report.write_text('{"schema_version":1,"complete":false,"cases":[]}\n')
    inputs = {root / path for path in SOURCES} | {Path(__file__).resolve()}
    for folder in ("Sources/AudioDSP", "Sources/NativeAudio", "Tests/NativeHALContractTests"):
        inputs.update((root / folder).rglob("*.hpp"))
    inputs.update((root / "Sources/NativeAudio/include").rglob("*.h"))

    def snapshot():
        return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(inputs)}

    before = snapshot()
    flags = ["-O0", "-g"] if args.configuration == "debug" else ["-O2", "-DNDEBUG"]
    executable = directory / "NativeHALContractTests"
    link_map = directory / "link-map.txt"
    # Do not link the NativeAudio product: its actual SystemHal provider must be unreachable here.
    command = ["xcrun", "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
               "-fno-exceptions", "-fno-rtti", "-mmacosx-version-min=15.4",
               "-I", "Sources/AudioDSP/include", "-I", "Sources/NativeAudio/include",
               *flags, *SOURCES, f"-Wl,-map,{link_map}", "-o", str(executable)]
    run(command, root, directory / "build.log")
    symbols = run(["xcrun", "nm", "-u", str(executable)], root,
                  directory / "undefined-symbols.log")
    require(not re.search(r"\b_Audio(?:Device|Hardware|Object)\w+", symbols),
            "The fake-HAL executable references a real stateful CoreAudio API; do not execute it.")
    linked = link_map.read_text()
    require("SystemHal.mm" not in linked and "SystemHal.o" not in linked,
            "The real HAL provider was linked into the fake-only unit executable.")
    run([str(executable), "--report", str(report)], root, directory / "run.log")
    result = json.loads(report.read_text())
    rows = result.get("cases", [])
    require(result.get("schema_version") == 1 and result.get("complete") is True and bool(rows),
            "The native unit report did not complete with named cases.")
    require(len({row["id"] for row in rows}) == len(rows), "Duplicate native unit report IDs.")
    require(all(row["status"] == "passed" and row["invocations"] > 0 and row["checks"] > 0
                and row["failures"] == 0 for row in rows), "A native unit case did not pass.")
    require(all(result.get(key) == 0 for key in
                ("callback_allocations", "callback_deletions", "owned_resources_at_end")),
            "The native callback allocated/deleted or left native resources owned.")
    after = snapshot()
    require(before == after, "Compiled native unit inputs changed during the run.")
    evidence = {"source_hashes_before": before, "source_hashes_after": after,
                "translation_units": len(SOURCES), "real_system_hal_linked": False,
                "command": command, "groups": len(rows),
                "invocations": sum(row["invocations"] for row in rows),
                "checks": sum(row["checks"] for row in rows)}
    (scratch / f"test-native-hal-inputs-{args.configuration}.json").write_text(
        json.dumps(evidence, indent=2) + "\n")
    print(f"Native fake-HAL units: {evidence['groups']} groups, "
          f"{evidence['invocations']} cases, {evidence['checks']} checks; no real HAL link.")


if __name__ == "__main__":
    main()
