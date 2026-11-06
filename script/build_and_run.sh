#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/macos/NETworkManager.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/NETworkManagerMac"

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --verify|verify) MODE="verify" ;;
    --debug|debug) MODE="debug" ;;
    --logs|logs) MODE="logs" ;;
    --telemetry|telemetry) MODE="telemetry" ;;
    run) MODE="run" ;;
    *) echo "Usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
  esac
done

process_uses_app_bundle() {
  local pid="$1"
  /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | /usr/bin/grep -Fqx "n$APP_EXECUTABLE"
}

app_pids() {
  while IFS= read -r pid; do
    if process_uses_app_bundle "$pid"; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x NETworkManagerMac 2>/dev/null || true)
}

stop_existing_app() {
  local pids pid attempt
  pids="$(app_pids)"
  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    process_uses_app_bundle "$pid" && /bin/kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"

  for attempt in {1..20}; do
    pids="$(app_pids)"
    [[ -n "$pids" ]] || return 0
    /bin/sleep 0.25
  done

  while IFS= read -r pid; do
    process_uses_app_bundle "$pid" && /bin/kill -KILL "$pid" 2>/dev/null || true
  done <<< "$pids"

  for attempt in {1..8}; do
    pids="$(app_pids)"
    [[ -z "$pids" ]] && return 0
    /bin/sleep 0.25
  done
  echo "Could not stop NETworkManagerMac from $APP_PATH" >&2
  return 1
}

stop_existing_app
"$ROOT_DIR/macos/Scripts/build-app.sh"

case "$MODE" in
  run)
    /usr/bin/open -n "$APP_PATH"
    ;;
  verify)
    /usr/bin/open -n "$APP_PATH"
    for _ in {1..20}; do
      if [[ -n "$(app_pids)" ]]; then
        echo "NETworkManagerMac is running from $APP_PATH"
        exit 0
      fi
      /bin/sleep 0.25
    done
    echo "NETworkManagerMac did not remain running from $APP_PATH" >&2
    exit 1
    ;;
  debug)
    lldb -- "$APP_PATH/Contents/MacOS/NETworkManagerMac"
    ;;
  logs)
    /usr/bin/open -n "$APP_PATH"
    /usr/bin/log stream --info --style compact --predicate 'process == "NETworkManagerMac"'
    ;;
  telemetry)
    /usr/bin/open -n "$APP_PATH"
    /usr/bin/log stream --info --style compact --predicate 'process == "NETworkManagerMac"'
    ;;
esac
