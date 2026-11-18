#!/usr/bin/env bash
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${NMCP_CONFIGURATION:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) printf '%s\n' 'NMCP_CONFIGURATION must be debug or release.' >&2; exit 2 ;;
esac
[[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]] || {
  printf '%s\n' 'NETworkManager MCP development runner requires an Apple Silicon Mac (arm64).' >&2
  exit 2
}

# SwiftPM maintains configuration links for both its native and Xcode build
# backends. Use the system file inspector for warm launches so architecture
# checks do not depend on the selected Xcode developer directory.
BINARY="$MACOS_DIR/.build/$CONFIGURATION/NMCP"
BUILD_REQUIRED=0
if [[ ! -x "$BINARY" ]]; then
  BUILD_REQUIRED=1
else
  if ! BINARY_TYPE="$(LC_ALL=C /usr/bin/file -Lb "$BINARY" </dev/null)"; then
    printf 'Unable to inspect cached NMCP binary: %s\n' "$BINARY" >&2
    exit 2
  fi
  [[ "$BINARY_TYPE" == "Mach-O 64-bit executable arm64" ]] || BUILD_REQUIRED=1
fi

if [[ "$BUILD_REQUIRED" == "1" ]]; then
  # Never let a first-use build read the client's queued initialize message.
  # Rebuild explicitly after source changes.
  swift build --package-path "$MACOS_DIR" --configuration "$CONFIGURATION" --product NMCP --triple arm64-apple-macos14 </dev/null >&2
  BIN_DIR="$(swift build --package-path "$MACOS_DIR" --configuration "$CONFIGURATION" --show-bin-path --triple arm64-apple-macos14 </dev/null)"
  BINARY="$BIN_DIR/NMCP"
fi

if ! BINARY_TYPE="$(LC_ALL=C /usr/bin/file -Lb "$BINARY" </dev/null)"; then
  printf 'Unable to inspect built NMCP binary: %s\n' "$BINARY" >&2
  exit 2
fi
[[ "$BINARY_TYPE" == "Mach-O 64-bit executable arm64" ]] || {
  printf 'NMCP requires a thin arm64 executable; found: %s\n' "$BINARY_TYPE" >&2
  exit 2
}

# stdout belongs exclusively to MCP. exec preserves the client's pipes and
# process ownership; stdin EOF terminates the server without a background job.
exec "$BINARY" "$@"
