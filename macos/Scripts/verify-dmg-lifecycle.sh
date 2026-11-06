#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || "$1" == "--help" || "$1" == "-h" ]]; then
  echo "Usage: $0 <NETworkManager DMG>" >&2
  exit $(( $# == 1 ? 0 : 2 ))
fi

DMG_PATH="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$DMG_PATH" ]] || { echo "DMG not found: $DMG_PATH" >&2; exit 2; }

TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE%/}"
[[ -n "$TEMP_BASE" ]] || TEMP_BASE="/tmp"
TEMP_ROOT="$(mktemp -d "$TEMP_BASE/networkmanager-macos-lifecycle.XXXXXX")"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
MOUNT_DIR="$TEMP_ROOT/mount"
INSTALL_DIR="$TEMP_ROOT/Applications"
SOURCE_APP="$MOUNT_DIR/NETworkManager.app"
INSTALL_APP="$INSTALL_DIR/NETworkManager.app"
INSTALL_EXECUTABLE="$INSTALL_APP/Contents/MacOS/NETworkManagerMac"
MOUNT_ATTACHED=0
mkdir -p "$MOUNT_DIR" "$INSTALL_DIR"
mkdir -p "$TEMP_ROOT/home"

app_pids() {
  local executable="$1"
  while IFS= read -r pid; do
    if /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/grep -Fqx "n$executable"; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x NETworkManagerMac 2>/dev/null || true)
}

stop_app() {
  local executable="$1" pids pid attempt
  pids="$(app_pids "$executable")"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
  for attempt in {1..20}; do
    pids="$(app_pids "$executable")"
    [[ -n "$pids" ]] || return 0
    /bin/sleep 0.25
  done
  while IFS= read -r pid; do
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"
  for attempt in {1..8}; do
    pids="$(app_pids "$executable")"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.25
  done
  echo "App process did not exit from $executable" >&2
  return 1
}

wait_for_app() {
  local executable="$1" attempt
  for attempt in {1..40}; do
    [[ -n "$(app_pids "$executable")" ]] && return 0
    /bin/sleep 0.25
  done
  echo "App did not start from $executable" >&2
  return 1
}

launch_app() {
  local executable="$1"
  CFFIXED_USER_HOME="$TEMP_ROOT/home" HOME="$TEMP_ROOT/home" "$executable" >/dev/null 2>&1 &
  disown "$!"
}

cleanup() {
  local result=$?
  trap - EXIT
  stop_app "$INSTALL_EXECUTABLE" || true
  if [[ "$MOUNT_ATTACHED" == "1" ]]; then
    /usr/bin/hdiutil detach -quiet "$MOUNT_DIR" 2>/dev/null || true
  fi
  /bin/rm -rf "$TEMP_ROOT"
  exit "$result"
}
trap cleanup EXIT

/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
MOUNT_ATTACHED=1
[[ -d "$SOURCE_APP" ]] || { echo "DMG does not contain NETworkManager.app" >&2; exit 1; }

verify_app() {
  local app="$1"
  /usr/bin/codesign --verify --deep --strict "$app"
  /usr/bin/plutil -lint "$app/Contents/Info.plist"
  [[ -x "$app/Contents/MacOS/NETworkManagerMac" ]]
}

echo "Testing install from mounted DMG..."
/usr/bin/ditto "$SOURCE_APP" "$INSTALL_APP"
verify_app "$INSTALL_APP"
launch_app "$INSTALL_EXECUTABLE"
wait_for_app "$INSTALL_EXECUTABLE"
stop_app "$INSTALL_EXECUTABLE"

echo "Testing replacement upgrade..."
UPGRADE_APP="$TEMP_ROOT/NETworkManager.upgrade.app"
OLD_APP="$TEMP_ROOT/NETworkManager.previous.app"
/usr/bin/ditto "$SOURCE_APP" "$UPGRADE_APP"
/bin/mv "$INSTALL_APP" "$OLD_APP"
/bin/mv "$UPGRADE_APP" "$INSTALL_APP"
verify_app "$INSTALL_APP"
/bin/rm -rf "$OLD_APP"
launch_app "$INSTALL_EXECUTABLE"
wait_for_app "$INSTALL_EXECUTABLE"
stop_app "$INSTALL_EXECUTABLE"

echo "Testing uninstall..."
/bin/rm -rf "$INSTALL_APP"
[[ ! -e "$INSTALL_APP" ]]
[[ -z "$(app_pids "$INSTALL_EXECUTABLE")" ]]
echo "DMG install, replacement upgrade, launch, and uninstall checks passed."
