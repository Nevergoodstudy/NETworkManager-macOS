#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 <NETworkManager.app>" >&2
  exit 2
fi

APP_PATH="$1"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSRequiresNativeExecution' "$APP_PATH/Contents/Info.plist")" == "true" ]] || {
  echo "App bundle must require native execution to prevent Rosetta launch." >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSArchitecturePriority:0' "$APP_PATH/Contents/Info.plist")" == "arm64" ]] || {
  echo "App bundle must prioritize arm64 execution." >&2
  exit 1
}
for binary in "$APP_PATH/Contents/MacOS/NETworkManagerMac" "$APP_PATH/Contents/Helpers/NMCP"; do
  [[ -x "$binary" ]] || { echo "Missing executable: $binary" >&2; exit 1; }
done

# Inspect all bundled Mach-O code, including future frameworks or helpers.
while IFS= read -r -d '' binary; do
  case "$(/usr/bin/file -b "$binary")" in
    *Mach-O*)
      architectures="$(/usr/bin/lipo -archs "$binary")"
      if [[ "$architectures" != "arm64" ]]; then
        echo "Apple Silicon package requires arm64 only; found $architectures in $binary" >&2
        exit 1
      fi
      ;;
  esac
done < <(/usr/bin/find "$APP_PATH" -type f -print0)

echo "Verified arm64-only app and bundled code: $APP_PATH"
