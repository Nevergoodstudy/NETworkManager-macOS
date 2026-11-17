#!/usr/bin/env python3
"""Verify architecture rejection before builds, signing, or output replacement."""

import os
from pathlib import Path
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

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    source = MACOS / "Sources/NMCore/PlatformRequirement.swift"
    for architecture in ["arm64", "x86_64"]:
        result = run(["xcrun", "swiftc", "-typecheck", "-sdk", sdk,
                      "-target", architecture + "-apple-macos14", str(source)])
        if architecture == "arm64":
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0 and "Intel builds are not supported" in result.stderr, result.stderr

print("Architecture policy passed: arm64 compiles; Intel/Universal requests fail without replacing outputs.")
