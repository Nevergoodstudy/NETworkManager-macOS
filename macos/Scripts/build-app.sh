#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MACOS_DIR/Resources/Info.plist")}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist/macos}"
APP_NAME="NETworkManager.app"
APP_DIR="$DIST_DIR/$APP_NAME"

# Field builds should remain reproducible when the Mac is on an isolated
# customer network. Package.resolved is the dependency contract for release
# artifacts; opt into resolver/network access explicitly when refreshing it.
set -- --package-path "$MACOS_DIR" --configuration "$CONFIGURATION" --triple arm64-apple-macos14
if [[ "${ALLOW_PACKAGE_RESOLUTION:-0}" != "1" ]]; then
  set -- "$@" --disable-automatic-resolution
fi

if [[ "$ARCHITECTURE" != "arm64" ]]; then
  echo "Unsupported architecture: $ARCHITECTURE. NETworkManager requires Apple Silicon (arm64); Intel and Universal builds are no longer supported." >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must contain four numeric components (for example, 2026.11.17.0)." >&2
  exit 2
fi

echo "Building NETworkManagerMac and NMCP for Apple Silicon (arm64)..."
swift build "$@" --product NETworkManagerMac
swift build "$@" --product NMCP
BIN_DIR="$(swift build "$@" --product NETworkManagerMac --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/NETworkManagerMac" "$APP_DIR/Contents/MacOS/NETworkManagerMac"
cp "$BIN_DIR/NMCP" "$APP_DIR/Contents/Helpers/NMCP"
cp "$MACOS_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%.*}" "$APP_DIR/Contents/Info.plist"
cp "$MACOS_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/ThirdPartyNotices.md"
cp "$MACOS_DIR/MCP.md" "$APP_DIR/Contents/Resources/MCP.md"

for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

"$SCRIPT_DIR/verify-arm64.sh" "$APP_DIR"

ICON_SOURCE="$REPO_DIR/Images/NETworkManager_512x512.png"
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 && [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/NETworkManager.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/NETworkManager.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string NETworkManager" "$APP_DIR/Contents/Info.plist"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/Helpers/NMCP"
  for bundle in "$APP_DIR/Contents/Resources/"*.bundle; do
    # SwiftPM can emit a plain resource directory without an Info.plist.
    # Its contents are sealed by the outer app; only real bundles need signing.
    [[ -f "$bundle/Contents/Info.plist" || -f "$bundle/Info.plist" ]] || continue
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bundle"
  done
  codesign --force --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --sign - "$APP_DIR/Contents/Helpers/NMCP"
  # An ad-hoc signature makes a locally built bundle launchable and lets
  # `codesign --verify --deep` validate the copied SwiftPM resource bundle.
  # Release builds should set CODESIGN_IDENTITY for Developer ID signing.
  for bundle in "$APP_DIR/Contents/Resources/"*.bundle; do
    [[ -f "$bundle/Contents/Info.plist" || -f "$bundle/Info.plist" ]] || continue
    codesign --force --sign - "$bundle"
  done
  codesign --force --sign - "$APP_DIR"
fi

echo "Created $APP_DIR"
echo "Run with: open \"$APP_DIR\""

if [[ "${CREATE_DMG:-0}" == "1" ]]; then
  DMG="$DIST_DIR/NETworkManager-macOS-$VERSION-$ARCHITECTURE.dmg"
  rm -f "$DMG"
  hdiutil create -volname NETworkManager -srcfolder "$APP_DIR" -ov -format UDZO "$DMG" >/dev/null
  echo "Created $DMG"
fi
