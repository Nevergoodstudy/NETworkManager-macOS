#!/usr/bin/env python3
"""Check storage migration and relaunch through an actual macOS app package.

Build the package first, then pass --app /path/to/NETworkManager.app. The signed
package is copied to a temporary path containing spaces and launched using
LaunchServices. Every launch has an isolated application support directory;
the user's application data and other running copies are never changed.
This checks persisted behavior, not the visual presentation of recovery errors.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


APPLICATION_ID = 0x4E4D4153
EXECUTABLE_NAME = "NETworkManagerMac"
TABLES = {
    "workspaces": "workspaces",
    "sites": "sites",
    "subnets": "subnets",
    "devices": "devices",
    "diagnosticRuns": "diagnostic_runs",
}
DATE_FIELDS = {"createdAt", "updatedAt", "startedAt", "finishedAt", "sourceFetchedAt"}
REFERENCE_DATE = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)


class CheckFailure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailure(message)


def command(arguments, timeout=10, accepted=(0,)):
    result = subprocess.run(
        [str(argument) for argument in arguments], capture_output=True,
        text=True, timeout=timeout, check=False,
    )
    if result.returncode not in accepted:
        raise CheckFailure(
            f"{arguments[0]} exited {result.returncode}: "
            f"{(result.stderr or result.stdout).strip()}"
        )
    return result


def owned_pids(executable):
    result = command(["/usr/bin/pgrep", "-x", EXECUTABLE_NAME], accepted=(0, 1))
    owned = []
    for value in result.stdout.splitlines():
        if not value.isdecimal():
            continue
        files = command(
            ["/usr/sbin/lsof", "-a", "-p", value, "-d", "txt", "-Fn"],
            accepted=(0, 1),
        )
        if f"n{executable}" in files.stdout.splitlines():
            owned.append(int(value))
    return owned


def stop_app(executable):
    for signum, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 3)):
        for pid in owned_pids(executable):
            try:
                os.kill(pid, signum)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not owned_pids(executable):
                return
            time.sleep(0.2)
    raise CheckFailure(f"Temporary app did not exit: {executable}")


def write_settings(support):
    support.mkdir(parents=True)
    # Assets has no command-line tool mapping; the supported saved selection
    # ensures that its real view initializes AssetStore in the packaged app.
    (support / "settings.json").write_text(json.dumps({
        "lastTool": "assets", "language": "english", "launchAtLogin": False,
        "showStatusBar": False, "windowWidth": 1280, "windowHeight": 820,
    }), encoding="utf-8")


def launch_app(app, support, log_prefix):
    executable = app / "Contents" / "MacOS" / EXECUTABLE_NAME
    check(not owned_pids(executable), "Temporary package is already running")
    command([
        "/usr/bin/open", "-n", "--env",
        f"NETWORKMANAGER_SUPPORT_DIRECTORY={support}",
        "--stdout", log_prefix.with_suffix(".stdout.log"),
        "--stderr", log_prefix.with_suffix(".stderr.log"), app,
    ], timeout=15)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if owned_pids(executable):
            return
        time.sleep(0.2)
    raise CheckFailure(f"LaunchServices did not start the copied package: {app}")


def wait_for(app, description, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    last_error = "condition is not ready"
    executable = app / "Contents" / "MacOS" / EXECUTABLE_NAME
    while time.monotonic() < deadline:
        check(owned_pids(executable), f"Packaged app exited while waiting for {description}")
        try:
            result = predicate()
            if result is not None and result is not False:
                return result
        except (CheckFailure, sqlite3.Error, OSError, json.JSONDecodeError) as error:
            last_error = str(error)
        time.sleep(0.2)
    raise CheckFailure(f"Timed out waiting for {description}: {last_error}")


def fixture():
    ids = [f"00000000-0000-0000-0000-{value:012d}" for value in range(1, 7)]
    workspace, site, subnet, device, completed, running = ids
    date = "2026-11-18T00:00:00Z"
    return {
        "workspaces": [{
            "id": workspace, "name": "Packaged migration 中文", "notes": "isolated fixture",
            "createdAt": date, "updatedAt": date,
        }],
        "sites": [{
            "id": site, "workspaceID": workspace, "name": "Fixture site",
            "location": "Loopback", "notes": "isolated fixture",
        }],
        "subnets": [{
            "id": subnet, "siteID": site, "name": "Loopback", "cidr": "127.0.0.0/8",
            "purpose": "packaged storage acceptance", "notes": "isolated fixture",
        }],
        "devices": [{
            "id": device, "siteID": site, "subnetID": subnet,
            "name": "Loopback fixture", "address": "127.0.0.1", "kind": "workstation",
            "vendor": "Apple", "role": "Test", "notes": "isolated 中文",
            "source": "packaged fixture", "sourceFetchedAt": date,
            "createdAt": date, "updatedAt": date,
        }],
        "diagnosticRuns": [{
            "id": completed, "deviceID": device, "kind": "dns", "status": "succeeded",
            "startedAt": date, "finishedAt": date, "parameters": {"query": "localhost"},
            "summary": "Stored completed result", "detail": "Preserved diagnostic detail 中文",
            "latency": 0.125, "source": "packaged fixture", "target": "localhost",
        }, {
            "id": running, "deviceID": device, "kind": "ping", "status": "running",
            "startedAt": date, "parameters": {"count": "4"},
            "summary": "Previous interrupted session", "detail": "Keep this diagnostic detail",
            "source": "packaged fixture", "target": "127.0.0.1",
        }],
    }


def encoded_dates(value):
    if isinstance(value, list):
        return [encoded_dates(item) for item in value]
    if isinstance(value, dict):
        return {
            key: ((datetime.datetime.fromisoformat(item.replace("Z", "+00:00")) - REFERENCE_DATE).total_seconds()
                  if key in DATE_FIELDS and isinstance(item, str) else encoded_dates(item))
            for key, item in value.items()
        }
    return value


def read_database(path):
    check(path.is_file(), "assets.sqlite has not been published")
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1) as database:
        check(database.execute("PRAGMA application_id").fetchone()[0] == APPLICATION_ID,
              "Unexpected SQLite application ID")
        check(database.execute("PRAGMA user_version").fetchone()[0] == 1,
              "Unexpected SQLite schema version")
        check(database.execute("PRAGMA quick_check").fetchall() == [("ok",)],
              "SQLite quick_check failed")
        check(not database.execute("PRAGMA foreign_key_check").fetchall(),
              "SQLite relationship check failed")
        check(database.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal",
              "Packaged app did not enable WAL mode")
        revision_row = database.execute("SELECT value FROM metadata WHERE key='revision'").fetchone()
        check(revision_row and revision_row[0], "SQLite revision is missing")
        snapshot = {}
        for field, table in TABLES.items():
            snapshot[field] = [
                json.loads(row[0])
                for row in database.execute(f"SELECT payload FROM {table} ORDER BY ordinal")
            ]
        return {"revision": revision_row[0], "snapshot": snapshot}


def verify_migration(path, expected):
    actual = read_database(path)
    snapshot = actual["snapshot"]
    runs = snapshot["diagnosticRuns"]
    check(len(runs) == 2, "Legacy diagnostic count changed")
    recovered = runs[1]
    check(recovered.get("status") == "interrupted", "Old running diagnostic was not recovered")
    check(recovered.get("summary") == "Interrupted when app closed", "Recovery summary was not saved")
    finished = recovered.get("finishedAt")
    now = (datetime.datetime.now(datetime.timezone.utc) - REFERENCE_DATE).total_seconds()
    check(isinstance(finished, (int, float)) and recovered["startedAt"] <= finished <= now + 5,
          "Recovered diagnostic has no valid finish time")
    comparable = json.loads(json.dumps(snapshot))
    comparable["diagnosticRuns"][1].pop("finishedAt")
    comparable["diagnosticRuns"][1]["status"] = "running"
    comparable["diagnosticRuns"][1]["summary"] = expected["diagnosticRuns"][1]["summary"]
    check(comparable == encoded_dates(expected), "Migrated records differ from the legacy fixture")
    return actual


def exercise(app, root):
    support = root / "Migrated Support"
    write_settings(support)
    expected = fixture()
    legacy = support / "assets.json"
    original = (json.dumps(expected, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    legacy.write_bytes(original)
    database = support / "assets.sqlite"
    executable = app / "Contents" / "MacOS" / EXECUTABLE_NAME

    print("Checking packaged launch, legacy migration, and interrupted-run recovery...", flush=True)
    launch_app(app, support, root / "migration")
    first = wait_for(app, "legacy migration and recovery", lambda: verify_migration(database, expected))
    check(legacy.read_bytes() == original, "Migration changed the original assets.json bytes")
    stop_app(executable)
    check(read_database(database) == first, "Shutdown changed the migrated data")

    print("Checking relaunch persistence and unchanged revision...", flush=True)
    # No app holds the isolated lock now. Its recreation proves the second
    # launch entered the repository rather than merely registering a process.
    lock = support / "assets.sqlite.lock"
    lock.unlink()
    launch_app(app, support, root / "relaunch")
    wait_for(app, "Assets repository initialization", lock.is_file)
    time.sleep(1)
    check(owned_pids(executable), "Relaunched package exited")
    check(read_database(database) == first, "Relaunch changed stored records or their revision")
    check(legacy.read_bytes() == original, "Relaunch changed the preserved assets.json")
    stop_app(executable)

    print("Checking damaged legacy data is preserved without publishing a database...", flush=True)
    damaged_support = root / "Damaged Support"
    write_settings(damaged_support)
    damaged = damaged_support / "assets.json"
    damaged_bytes = b'{"workspaces": [damaged legacy fixture\x00\xff\n'
    damaged.write_bytes(damaged_bytes)
    launch_app(app, damaged_support, root / "damaged")
    wait_for(app, "damaged-data recovery attempt", lambda: (damaged_support / "assets.sqlite.lock").is_file())
    time.sleep(1)
    check(owned_pids(executable), "Packaged app exited after reading damaged legacy data")
    check(damaged.read_bytes() == damaged_bytes, "Damaged legacy bytes were changed")
    check(not (damaged_support / "assets.sqlite").exists(), "Damaged JSON published an empty SQLite database")
    check(not (damaged_support / "assets.sqlite.initialized").exists(), "Damaged JSON was marked as initialized")
    stop_app(executable)
    check(damaged.read_bytes() == damaged_bytes, "Shutdown changed damaged legacy bytes")
    check(not (damaged_support / "assets.sqlite").exists(), "Shutdown published a database over damaged JSON")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="Built NETworkManager.app package")
    parser.add_argument("--keep-fixtures", action="store_true", help="Keep isolated fixtures and logs after completion")
    arguments = parser.parse_args()
    app_source = arguments.app.expanduser().resolve()
    check(sys.platform == "darwin", "This acceptance script requires macOS LaunchServices")
    check(app_source.suffix == ".app" and app_source.is_dir(), f"App package not found: {app_source}")
    source_executable = app_source / "Contents" / "MacOS" / EXECUTABLE_NAME
    check(source_executable.is_file() and os.access(source_executable, os.X_OK),
          f"Packaged executable not found: {source_executable}")
    root = Path(tempfile.mkdtemp(prefix="networkmanager packaged storage ")).resolve()
    app = root / "Applications With Spaces" / "NETworkManager.app"
    executable = app / "Contents" / "MacOS" / EXECUTABLE_NAME
    result = 1
    keep_fixtures = arguments.keep_fixtures
    try:
        app.parent.mkdir()
        command(["/usr/bin/ditto", app_source, app], timeout=60)
        command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], timeout=30)
        exercise(app, root)
        print("Packaged storage acceptance passed: migration, recovery, persistence, and damaged-data preservation.")
        result = 0
    except (CheckFailure, OSError, ValueError, subprocess.TimeoutExpired, sqlite3.Error) as error:
        print(f"Packaged storage acceptance failed: {error}", file=sys.stderr)
        for log in sorted(root.glob("*.log")):
            contents = log.read_text(encoding="utf-8", errors="replace")[-6000:]
            if contents:
                print(f"\n{log.name}:\n{contents}", file=sys.stderr)
    finally:
        try:
            stop_app(executable)
        except (CheckFailure, OSError, subprocess.TimeoutExpired) as error:
            print(f"Temporary app cleanup failed: {error}", file=sys.stderr)
            result = 1
            keep_fixtures = True
        if keep_fixtures:
            print(f"Isolated fixtures and logs retained: {root}")
        else:
            shutil.rmtree(root)
    return result


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (CheckFailure, OSError) as error:
        print(f"Packaged storage acceptance failed: {error}", file=sys.stderr)
        sys.exit(1)
