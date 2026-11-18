#!/usr/bin/env python3
"""Verify architecture rejection before builds, signing, or output replacement."""

import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


MACOS = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=60, **kwargs)


with tempfile.TemporaryDirectory(prefix="networkmanager-architecture-") as directory:
    output = Path(directory) / "output"
    output.mkdir()
    marker = output / "keep-existing-artifact"
    marker.write_text("preserved")
    for architecture in ["x86_64", "universal", "i386"]:
        for script, arguments in [("build-app.sh", []), ("release-dmg.sh", []),
                                  ("release-dmg.sh", ["--dry-run"])]:
            environment = {**os.environ, "ARCHITECTURE": architecture, "DIST_DIR": str(output)}
            result = run([str(MACOS / "Scripts" / script), *arguments], env=environment)
            assert result.returncode != 0 and "requires Apple Silicon (arm64)" in result.stderr, result
            assert list(output.iterdir()) == [marker] and marker.read_text() == "preserved"

    # Exercise the real launcher in an isolated SwiftPM layout. A cached
    # executable of another type must request an explicit arm64 rebuild, and
    # an invalid result from that rebuild must never be executed.
    launcher_root = Path(directory) / "launcher with spaces"
    scripts = launcher_root / "Scripts"
    scripts.mkdir(parents=True)
    launcher = scripts / "run-mcp.sh"
    shutil.copy2(MACOS / "Scripts/run-mcp.sh", launcher)
    binary = launcher_root / ".build/release/NMCP"
    binary.parent.mkdir(parents=True)
    guards = launcher_root / "guards"
    guards.mkdir()
    swift = guards / "swift"
    swift.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$NMCP_BUILD_LOG"\nexit 91\n')
    swift.chmod(0o755)
    build_log = launcher_root / "build.log"
    executed = launcher_root / "unexpected-execution"
    environment = {**os.environ, "NMCP_CONFIGURATION": "release", "NMCP_BUILD_LOG": str(build_log),
                   "PATH": str(guards) + os.pathsep + os.environ.get("PATH", os.defpath)}

    def header(cpu, subtype=0):
        return struct.pack("<8I", 0xFEEDFACF, cpu, subtype, 2, 0, 0, 0, 0)

    universal = (struct.pack(">2I", 0xCAFEBABE, 2) +
                 struct.pack(">5I", 0x0100000C, 0, 4096, 32, 12) +
                 struct.pack(">5I", 0x01000007, 3, 8192, 32, 12))
    universal = universal.ljust(4096, b"\0") + header(0x0100000C)
    universal = universal.ljust(8192, b"\0") + header(0x01000007, 3)
    fixtures = {"Intel": header(0x01000007, 3), "arm64e": header(0x0100000C, 2),
                "Universal": universal, "script": b'#!/bin/sh\n: > "$NMCP_EXECUTED"\n'}
    environment["NMCP_EXECUTED"] = str(executed)
    for name, contents in fixtures.items():
        binary.write_bytes(contents)
        binary.chmod(0o755)
        if build_log.exists():
            build_log.unlink()
        result = run([str(launcher), "--version"], env=environment, input="queued-client-input\n")
        assert result.returncode == 91, (name, result)
        assert "--triple arm64-apple-macos14" in build_log.read_text(), (name, result)
        assert not executed.exists(), (name, result)

    swift.write_text('#!/bin/sh\ncase " $* " in\n  *" --show-bin-path "*) printf "%s\\n" "$NMCP_TEST_BIN_DIR" ;;\nesac\n')
    environment["NMCP_TEST_BIN_DIR"] = str(binary.parent)
    result = run([str(launcher), "--version"], env=environment, input="queued-client-input\n")
    assert result.returncode == 2 and "requires a thin arm64 executable" in result.stderr, result
    assert not executed.exists(), result

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    source = MACOS / "Sources/NMCore/PlatformRequirement.swift"
    for architecture in ["arm64", "x86_64"]:
        result = run(["xcrun", "swiftc", "-typecheck", "-sdk", sdk,
                      "-target", architecture + "-apple-macos14", str(source)])
        if architecture == "arm64":
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0 and "Intel builds are not supported" in result.stderr, result.stderr

print("Architecture policy passed: arm64 compiles; Intel/Universal requests fail without replacing outputs; "
      "launcher rebuilds incompatible caches and rejects an invalid build result.")
