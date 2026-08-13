#!/bin/sh
set -eu

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

ROOT="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
ARCHIVE="${CI_ARCHIVE_PATH:?CI_ARCHIVE_PATH is required after Archive}"
CONFIG="$ROOT/release/release-requirements.json"
CONFIG_READER="$ROOT/scripts/release_config_value.py"
INFO="$ARCHIVE/Info.plist"

fail() {
  echo "error: archive verification failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "missing required tool: python3"
[ -f "$CONFIG" ] || fail "release requirements are missing"
[ -f "$CONFIG_READER" ] || fail "release config reader is missing"
[ -f "$INFO" ] || fail "archive Info.plist not found"
EXPECTED_BUNDLE_ID=$(python3 "$CONFIG_READER" "$CONFIG" bundleIdentifier)
ARCHIVE_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleIdentifier' "$INFO")
ARCHIVE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$INFO")
ARCHIVE_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$INFO")

[ "$ARCHIVE_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "archive bundle ID is $ARCHIVE_BUNDLE_ID; expected $EXPECTED_BUNDLE_ID"
[ -n "$ARCHIVE_VERSION" ] || fail "archive marketing version is empty"
case "$ARCHIVE_BUILD" in *[!0-9]*|'') fail "archive build number is not an integer: '$ARCHIVE_BUILD'" ;; esac
if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  [ "$ARCHIVE_BUILD" = "$CI_BUILD_NUMBER" ] || fail "archive build $ARCHIVE_BUILD does not match Xcode Cloud build $CI_BUILD_NUMBER"
fi

APP_DIR="$ARCHIVE/Products/Applications"
find "$APP_DIR" -type f -name PrivacyInfo.xcprivacy -print -quit | grep -q . || fail "PrivacyInfo.xcprivacy is missing from the archived app"
for forbidden in 01-gallery-portal.png 02-memory-mosaic.png 03-quiet-window.png 04-woven-moments.png 05-memory-orbit.png GENERATION_NOTES.md; do
  if find "$APP_DIR" -type f -name "$forbidden" -print -quit | grep -q .; then
    fail "development-only asset was bundled: $forbidden"
  fi
done

echo "Archive verification OK: $ARCHIVE_BUNDLE_ID $ARCHIVE_VERSION ($ARCHIVE_BUILD)"
