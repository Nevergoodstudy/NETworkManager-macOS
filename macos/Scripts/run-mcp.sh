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

# Use the explicit arm64 build directory, never a host-dependent shortcut.
# Avoid invoking SwiftPM at all on a warm launch: even --show-bin-path can
# wait for another build's package lock and consume the handshake timeout.
BINARY="$MACOS_DIR/.build/arm64-apple-macos/$CONFIGURATION/NMCP"
if [[ ! -x "$BINARY" ]]; then
  # Never let a first-use build read the client's queued initialize message.
  # Rebuild explicitly after source changes.
  swift build --package-path "$MACOS_DIR" --configuration "$CONFIGURATION" --product NMCP --triple arm64-apple-macos14 </dev/null >&2
  BIN_DIR="$(swift build --package-path "$MACOS_DIR" --configuration "$CONFIGURATION" --show-bin-path --triple arm64-apple-macos14 </dev/null)"
  BINARY="$BIN_DIR/NMCP"
fi

[[ "$(/usr/bin/lipo -archs "$BINARY")" == "arm64" ]] || {
  printf '%s\n' 'NMCP requires an arm64-only binary. Rebuild NMCP for Apple Silicon.' >&2
  exit 2
}

# stdout belongs exclusively to MCP. exec preserves the client's pipes and
# process ownership; stdin EOF terminates the server without a background job.
exec "$BINARY" "$@"
