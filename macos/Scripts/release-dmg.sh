#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
VERSION="${VERSION:-2026.7.7.0}"
ARCHITECTURE="${ARCHITECTURE:-universal}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist/macos}"
APP_PATH="$DIST_DIR/NETworkManager.app"
DMG_PATH="$DIST_DIR/NETworkManager-macOS-$VERSION-$ARCHITECTURE.dmg"
SUBMISSION_PATH="$DIST_DIR/notarization-submission.json"
NOTARY_LOG_PATH="$DIST_DIR/notarization-log.json"

fail() {
  printf 'release-dmg: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: macos/Scripts/release-dmg.sh [--dry-run]

Builds a Developer ID signed app, creates a DMG, submits it to Apple Notary
Service, staples the accepted ticket, and validates the DMG with stapler and
Gatekeeper.

Required environment:
  CODESIGN_IDENTITY  Developer ID Application identity installed in Keychain
  NOTARY_PROFILE     Profile previously created with `xcrun notarytool store-credentials`

Optional environment:
  ARCHITECTURE       universal (default), arm64, or x86_64
  VERSION            Artifact version (default: 2026.7.7.0)
  DIST_DIR           Output directory (default: dist/macos)
  NOTARY_KEYCHAIN    Keychain path containing NOTARY_PROFILE

--dry-run prints the release steps and missing prerequisites. It does not
build, sign, upload, staple, or certify an artifact.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ $# -gt 0 ]]; then
  usage >&2
  exit 2
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY RUN: would build %s for %s, sign with Developer ID, submit to Apple Notary Service, staple, and Gatekeeper-check %s\n' \
    "$APP_PATH" "$ARCHITECTURE" "$DMG_PATH"
  [[ -n "${CODESIGN_IDENTITY:-}" ]] || printf 'Missing prerequisite: CODESIGN_IDENTITY\n'
  [[ -n "${NOTARY_PROFILE:-}" ]] || printf 'Missing prerequisite: NOTARY_PROFILE\n'
  printf 'No build, signing, notarization, stapling, or Gatekeeper assessment was performed.\n'
  exit 0
fi

[[ -n "${CODESIGN_IDENTITY:-}" ]] || fail "Set CODESIGN_IDENTITY to an installed Developer ID Application identity."
[[ -n "${NOTARY_PROFILE:-}" ]] || fail "Set NOTARY_PROFILE to a profile created with xcrun notarytool store-credentials."
[[ "$ARCHITECTURE" == "universal" ]] || fail "Formal DMG release requires ARCHITECTURE=universal."

for tool in swift codesign xcrun hdiutil lipo security spctl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
done

IDENTITIES="$(security find-identity -v -p codesigning 2>&1)" \
  || fail "Could not read code-signing identities from Keychain."
printf '%s\n' "$IDENTITIES" | grep -Fq -- "\"$CODESIGN_IDENTITY\"" \
  || fail "CODESIGN_IDENTITY is not present in the current Keychain: $CODESIGN_IDENTITY"

NOTARY_PREFLIGHT_ARGS=(--keychain-profile "$NOTARY_PROFILE" --output-format json --no-progress)
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_PREFLIGHT_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi
if ! xcrun notarytool history "${NOTARY_PREFLIGHT_ARGS[@]}" >/dev/null 2>&1; then
  fail "NOTARY_PROFILE is unavailable or cannot authenticate with Apple Notary Service. Check the profile, keychain, and network."
fi

mkdir -p "$DIST_DIR"
printf 'Building and signing the universal app...\n'
ARCHITECTURE="$ARCHITECTURE" VERSION="$VERSION" DIST_DIR="$DIST_DIR" \
  CREATE_DMG=1 CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  "$SCRIPT_DIR/build-app.sh"

[[ -d "$APP_PATH" ]] || fail "App bundle was not created: $APP_PATH"
[[ -f "$DMG_PATH" ]] || fail "DMG was not created: $DMG_PATH"

printf 'Verifying app signature and hardened runtime...\n'
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)" \
  || fail "Could not read app signature details."
printf '%s\n' "$SIGNATURE_DETAILS" | grep -Fq -- "Authority=$CODESIGN_IDENTITY" \
  || fail "App signature does not match CODESIGN_IDENTITY."
printf '%s\n' "$SIGNATURE_DETAILS" | grep -Eq 'flags=.*runtime' \
  || fail "App signature is missing the Hardened Runtime flag."

APP_ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/NETworkManagerMac")"
for architecture in arm64 x86_64; do
  [[ " $APP_ARCHS " == *" $architecture "* ]] \
    || fail "Universal app is missing architecture $architecture (found: $APP_ARCHS)."
done

printf 'Submitting DMG to Apple Notary Service...\n'
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE" --wait --output-format json --no-progress)
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
  NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" > "$SUBMISSION_PATH" || NOTARY_EXIT_CODE=$?
NOTARY_EXIT_CODE="${NOTARY_EXIT_CODE:-0}"
SUBMISSION_ID="$(jq -r '.id // empty' "$SUBMISSION_PATH" 2>/dev/null || true)"
SUBMISSION_STATUS="$(jq -r '.status // empty' "$SUBMISSION_PATH" 2>/dev/null || true)"
if [[ "$NOTARY_EXIT_CODE" -ne 0 || "$SUBMISSION_STATUS" != "Accepted" ]]; then
  if [[ -n "$SUBMISSION_ID" ]]; then
    NOTARY_LOG_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
      NOTARY_LOG_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
    fi
    xcrun notarytool log "$SUBMISSION_ID" "$NOTARY_LOG_PATH" "${NOTARY_LOG_ARGS[@]}" \
      || printf 'Could not retrieve the notary log for submission %s.\n' "$SUBMISSION_ID" >&2
  fi
  fail "Notarization failed with exit code $NOTARY_EXIT_CODE and status '$SUBMISSION_STATUS'. Review submission details: $SUBMISSION_PATH"
fi

printf 'Stapling and validating notarization ticket...\n'
xcrun stapler staple -v "$DMG_PATH"
xcrun stapler validate -v "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

printf 'Notarized and Gatekeeper-validated DMG: %s\n' "$DMG_PATH"
printf 'Notary submission details: %s\n' "$SUBMISSION_PATH"
