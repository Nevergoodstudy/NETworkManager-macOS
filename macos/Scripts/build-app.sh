#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-$(uname -m)}"
VERSION="${VERSION:-2026.7.7.0}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist/macos}"
APP_NAME="NETworkManager.app"
APP_DIR="$DIST_DIR/$APP_NAME"

case "$ARCHITECTURE" in
  arm64|x86_64|universal) ;;
  *) echo "Unsupported architecture: $ARCHITECTURE (use arm64, x86_64, or universal)" >&2; exit 2 ;;
esac

BUILD_TMP=""
if [[ "$ARCHITECTURE" == "universal" ]]; then
  echo "Building NETworkManagerMac and NMCP for arm64 and x86_64..."
  BUILD_TMP="$(mktemp -d)"
  for build_arch in arm64 x86_64; do
    swift build --package-path "$MACOS_DIR" --product NETworkManagerMac \
      --configuration "$CONFIGURATION" --triple "$build_arch-apple-macos14"
    swift build --package-path "$MACOS_DIR" --product NMCP \
      --configuration "$CONFIGURATION" --triple "$build_arch-apple-macos14"
    build_bin_dir="$(swift build --package-path "$MACOS_DIR" --show-bin-path \
      --product NETworkManagerMac --configuration "$CONFIGURATION" \
      --triple "$build_arch-apple-macos14")"
    cp "$build_bin_dir/NETworkManagerMac" "$BUILD_TMP/NETworkManagerMac-$build_arch"
    cp "$build_bin_dir/NMCP" "$BUILD_TMP/NMCP-$build_arch"
    BIN_DIR="$build_bin_dir"
  done
else
  echo "Building NETworkManagerMac and NMCP for $ARCHITECTURE..."
  swift build --package-path "$MACOS_DIR" --product NETworkManagerMac \
    --configuration "$CONFIGURATION" --triple "$ARCHITECTURE-apple-macos14"
  swift build --package-path "$MACOS_DIR" --product NMCP \
    --configuration "$CONFIGURATION" --triple "$ARCHITECTURE-apple-macos14"
  BIN_DIR="$(swift build --package-path "$MACOS_DIR" --show-bin-path \
    --product NETworkManagerMac --configuration "$CONFIGURATION" \
    --triple "$ARCHITECTURE-apple-macos14")"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources"
if [[ "$ARCHITECTURE" == "universal" ]]; then
  lipo -create "$BUILD_TMP/NETworkManagerMac-arm64" "$BUILD_TMP/NETworkManagerMac-x86_64" \
    -output "$APP_DIR/Contents/MacOS/NETworkManagerMac"
  lipo -create "$BUILD_TMP/NMCP-arm64" "$BUILD_TMP/NMCP-x86_64" \
    -output "$APP_DIR/Contents/Helpers/NMCP"
  rm -rf "$BUILD_TMP"
else
  cp "$BIN_DIR/NETworkManagerMac" "$APP_DIR/Contents/MacOS/NETworkManagerMac"
  cp "$BIN_DIR/NMCP" "$APP_DIR/Contents/Helpers/NMCP"
fi
cp "$MACOS_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$MACOS_DIR/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/ThirdPartyNotices.md"
cp "$MACOS_DIR/MCP.md" "$APP_DIR/Contents/Resources/MCP.md"

for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

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
    [[ ! -e "$bundle" ]] || codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$bundle"
  done
  codesign --force --options runtime --timestamp \
    --sign "$CODESIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --sign - "$APP_DIR/Contents/Helpers/NMCP"
  # An ad-hoc signature makes a locally built bundle launchable and lets
  # `codesign --verify --deep` validate the copied SwiftPM resource bundle.
  # Release builds should set CODESIGN_IDENTITY for Developer ID signing.
  for bundle in "$APP_DIR/Contents/Resources/"*.bundle; do
    [[ ! -e "$bundle" ]] || codesign --force --sign - "$bundle"
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
