#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
CONFIG="$ROOT/release/release-requirements.json"

fail() {
  echo "error: release requirement failed: $*" >&2
  exit 1
}

for tool in jq xcodebuild xcrun plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
[ -f "$CONFIG" ] || fail "missing $CONFIG"

PROJECT=$(jq -er '.project' "$CONFIG")
SCHEME=$(jq -er '.scheme' "$CONFIG")
EXPECTED_BUNDLE_ID=$(jq -er '.bundleIdentifier' "$CONFIG")
PRIVACY_MANIFEST=$(jq -er '.privacyManifest' "$CONFIG")
MIN_XCODE=$(jq -er '.minimumXcodeMajor' "$CONFIG")
MIN_SDK=$(jq -er '.minimumIPhoneOSSDKMajor' "$CONFIG")

cd "$ROOT"

XCODE_VERSION=$(xcodebuild -version | sed -n '1s/^Xcode //p')
XCODE_MAJOR=$(printf '%s' "$XCODE_VERSION" | cut -d. -f1)
case "$XCODE_MAJOR" in *[!0-9]*|'') fail "could not determine Xcode version" ;; esac
[ "$XCODE_MAJOR" -ge "$MIN_XCODE" ] || fail "Xcode $XCODE_VERSION is unsupported; Xcode $MIN_XCODE+ is required"

SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
SDK_MAJOR=$(printf '%s' "$SDK_VERSION" | cut -d. -f1)
case "$SDK_MAJOR" in *[!0-9]*|'') fail "could not determine iPhoneOS SDK version" ;; esac
[ "$SDK_MAJOR" -ge "$MIN_SDK" ] || fail "iPhoneOS SDK $SDK_VERSION is unsupported; SDK $MIN_SDK+ is required"

SCHEME_FILE="$PROJECT/xcshareddata/xcschemes/$SCHEME.xcscheme"
[ -f "$SCHEME_FILE" ] || fail "shared scheme not found: $SCHEME_FILE"
grep -q 'buildForArchiving = "YES"' "$SCHEME_FILE" || fail "$SCHEME shared scheme is not enabled for Archive"
[ -f "$PRIVACY_MANIFEST" ] || fail "privacy manifest not found: $PRIVACY_MANIFEST"
plutil -lint "$PRIVACY_MANIFEST" >/dev/null || fail "privacy manifest is invalid"

SETTINGS=$(mktemp)
trap 'rm -f "$SETTINGS"' EXIT HUP INT TERM
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings >"$SETTINGS"

setting() {
  awk -F ' = ' -v key="$1" '$1 ~ ("[[:space:]]" key "$") { print $2; exit }' "$SETTINGS"
}

BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER)
MARKETING_VERSION=$(setting MARKETING_VERSION)
PROJECT_BUILD=$(setting CURRENT_PROJECT_VERSION)
CODE_SIGN_STYLE=$(setting CODE_SIGN_STYLE)

[ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || fail "bundle identifier is $BUNDLE_ID; expected $EXPECTED_BUNDLE_ID"
[ -n "$MARKETING_VERSION" ] || fail "MARKETING_VERSION is empty"
case "$PROJECT_BUILD" in *[!0-9]*|'') fail "CURRENT_PROJECT_VERSION must be a positive integer; got '$PROJECT_BUILD'" ;; esac
[ "$PROJECT_BUILD" -gt 0 ] || fail "CURRENT_PROJECT_VERSION must be positive"
[ "$CODE_SIGN_STYLE" = "Automatic" ] || fail "Release signing must be Automatic"

PBXPROJ="$PROJECT/project.pbxproj"
if grep -Eq 'IconOptions|01-gallery-portal|02-memory-mosaic|03-quiet-window|04-woven-moments|05-memory-orbit|GENERATION_NOTES' "$PBXPROJ"; then
  fail "development-only IconOptions assets are still referenced by the generated project"
fi

echo "Release requirements OK: Xcode $XCODE_VERSION, iPhoneOS SDK $SDK_VERSION, $BUNDLE_ID $MARKETING_VERSION ($PROJECT_BUILD)"
