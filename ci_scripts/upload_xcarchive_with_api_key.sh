#!/bin/sh
# Export an existing .xcarchive and upload it with an App Store Connect API key.
# This bypasses Xcode Cloud's Apple ID Session Proxy Provider
# ("Prepare Build for App Store Connect"), which archived ClimateIQ #81–#84
# successfully and then failed authentication for team 575UAD2C77.
#
# Required: ASC_KEY_ID, ASC_ISSUER_ID, and one of ASC_PRIVATE_KEY,
# ASC_KEY_BASE64, or ASC_PRIVATE_KEY_PATH.
# Required: ARCHIVE_PATH or CI_ARCHIVE_PATH
# Optional: ASC_APP_ID, ASC_BETA_GROUP_ID, ASC_TEAM_ID
set -eu

TEAM_ID="${ASC_TEAM_ID:-575UAD2C77}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${CI_ARCHIVE_PATH:-}}"
BUILD_NUMBER="${CI_BUILD_NUMBER:-$(date +%s)}"
ASSIGN_TIMEOUT="${ASC_BETA_ASSIGNMENT_TIMEOUT_SECONDS:-1800}"

fail() {
  echo "upload_xcarchive_with_api_key: $*" >&2
  exit 1
}

has_api_key() {
  [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && {
    [ -n "${ASC_PRIVATE_KEY:-}" ] || [ -n "${ASC_KEY_BASE64:-}" ] || [ -n "${ASC_PRIVATE_KEY_PATH:-}" ]
  }
}

if ! has_api_key; then
  echo "upload_xcarchive_with_api_key: skipping; set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY (or ASC_KEY_BASE64) in the Xcode Cloud workflow" >&2
  echo "upload_xcarchive_with_api_key: without the API key, Archive still depends on Session Proxy Provider and will fail at PrepareBuildForAppStoreConnect" >&2
  exit 0
fi

[ -n "$ARCHIVE_PATH" ] || fail "ARCHIVE_PATH / CI_ARCHIVE_PATH is not set"
[ -d "$ARCHIVE_PATH" ] || fail "archive not found: $ARCHIVE_PATH"

WORK_DIR="${TMPDIR:-/tmp}/asc-api-upload-$BUILD_NUMBER"
KEY_DIR="$WORK_DIR/private_keys"
KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
EXPORT_PATH="$WORK_DIR/export"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"

rm -rf "$WORK_DIR"
mkdir -p "$KEY_DIR" "$EXPORT_PATH"

if [ -n "${ASC_PRIVATE_KEY_PATH:-}" ]; then
  [ -f "$ASC_PRIVATE_KEY_PATH" ] || fail "ASC_PRIVATE_KEY_PATH is not readable"
  cp "$ASC_PRIVATE_KEY_PATH" "$KEY_PATH"
elif [ -n "${ASC_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY_PATH"
elif [ -n "${ASC_KEY_BASE64:-}" ]; then
  if printf '%s' "dGVzdA==" | base64 -D >/dev/null 2>&1; then
    printf '%s' "$ASC_KEY_BASE64" | tr -d '\n' | base64 -D > "$KEY_PATH"
  else
    printf '%s' "$ASC_KEY_BASE64" | tr -d '\n' | base64 -d > "$KEY_PATH"
  fi
fi
chmod 600 "$KEY_PATH"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST

echo "upload_xcarchive_with_api_key: exporting IPA from $ARCHIVE_PATH"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$IPA_PATH" ] || fail "export succeeded but no IPA was found in $EXPORT_PATH"

echo "upload_xcarchive_with_api_key: uploading $IPA_PATH with API key $ASC_KEY_ID"
xcrun altool \
  --upload-app \
  -f "$IPA_PATH" \
  -t ios \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID" \
  --p8-file-path "$KEY_PATH" \
  --output-format xml

echo "upload_xcarchive_with_api_key: upload submitted"

if [ -z "${ASC_APP_ID:-}" ]; then
  echo "upload_xcarchive_with_api_key: set ASC_APP_ID to wait for processing and submit for review" >&2
  exit 0
fi

JWT_OUTPUT="$(xcrun altool \
  --generate-jwt \
  --api-key "$ASC_KEY_ID" \
  --api-issuer "$ASC_ISSUER_ID" \
  --p8-file-path "$KEY_PATH" 2>&1 >/dev/null || true)"
ASC_JWT="$(printf '%s\n' "$JWT_OUTPUT" | awk '/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/ { token = $0 } END { print token }')"

if [ -z "$ASC_JWT" ]; then
  echo "upload_xcarchive_with_api_key: upload submitted, but altool did not return a REST token" >&2
  if [ -n "${ASC_SHIP_SCRIPT:-}" ] && [ -f "$ASC_SHIP_SCRIPT" ]; then
    ASC_PRIVATE_KEY_PATH="$KEY_PATH" python3 "$ASC_SHIP_SCRIPT" --submit-only --app-id "$ASC_APP_ID" --build-number "$BUILD_NUMBER" --root "${CI_PRIMARY_REPOSITORY_PATH:-.}"
  fi
  exit 0
fi

ASC_API_ROOT="https://api.appstoreconnect.apple.com/v1"
BUILDS_QUERY="builds?filter%5Bapp%5D=$ASC_APP_ID&filter%5Bversion%5D=$BUILD_NUMBER&fields%5Bbuilds%5D=version,processingState,uploadedDate,betaGroups&include=betaGroups&sort=-uploadedDate&limit=1"
DEADLINE=$(( $(date +%s) + ASSIGN_TIMEOUT ))
BUILD_ID=""
PROCESSING_STATE=""

echo "upload_xcarchive_with_api_key: waiting for build $BUILD_NUMBER to become VALID"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  BUILDS_RESPONSE="$(curl -fsS \
    -H "Authorization: Bearer $ASC_JWT" \
    -H "Accept: application/json" \
    "$ASC_API_ROOT/$BUILDS_QUERY" || true)"

  BUILD_STATUS="$(printf '%s' "$BUILDS_RESPONSE" | /usr/bin/python3 -c 'import json, sys
try:
    payload = json.load(sys.stdin)
    build = (payload.get("data") or [None])[0]
except Exception:
    build = None
if build:
    print(build.get("id", "") + " " + (build.get("attributes", {}).get("processingState") or ""))
' 2>/dev/null || true)"

  BUILD_ID="${BUILD_STATUS%% *}"
  PROCESSING_STATE="${BUILD_STATUS#* }"

  if [ -n "$BUILD_ID" ] && [ "$PROCESSING_STATE" = "VALID" ]; then
    break
  fi
  if [ -n "$BUILD_ID" ] && { [ "$PROCESSING_STATE" = "FAILED" ] || [ "$PROCESSING_STATE" = "INVALID" ]; }; then
    fail "App Store Connect processing finished with state $PROCESSING_STATE for build $BUILD_NUMBER"
  fi
  sleep 30
done

if [ -z "$BUILD_ID" ] || [ "$PROCESSING_STATE" != "VALID" ]; then
  echo "upload_xcarchive_with_api_key: upload submitted, but build $BUILD_NUMBER did not become VALID before timeout" >&2
  exit 0
fi

if [ -n "${ASC_BETA_GROUP_ID:-}" ]; then
  RELATIONSHIP_BODY="$(printf '{"data":[{"type":"builds","id":"%s"}]}' "$BUILD_ID")"
  curl -fsS \
    -X POST \
    -H "Authorization: Bearer $ASC_JWT" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$RELATIONSHIP_BODY" \
    "$ASC_API_ROOT/betaGroups/$ASC_BETA_GROUP_ID/relationships/builds" >/dev/null
  echo "upload_xcarchive_with_api_key: assigned build $BUILD_NUMBER to TestFlight group $ASC_BETA_GROUP_ID"
else
  echo "upload_xcarchive_with_api_key: skipping TestFlight assignment (set ASC_BETA_GROUP_ID)"
fi

if [ -n "${ASC_SHIP_SCRIPT:-}" ] && [ -f "$ASC_SHIP_SCRIPT" ]; then
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    ASC_VERSION="${ASC_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE_PATH/Info.plist" 2>/dev/null || true)}"
  fi
  echo "upload_xcarchive_with_api_key: submitting $ASC_VERSION ($BUILD_NUMBER) for App Store review"
  ASC_PRIVATE_KEY_PATH="$KEY_PATH" \
  ASC_BUILD_ID="$BUILD_ID" \
  ASC_VERSION="$ASC_VERSION" \
  python3 "$ASC_SHIP_SCRIPT" --submit-only --app-id "$ASC_APP_ID" --build-id "$BUILD_ID" --version "$ASC_VERSION" --root "${CI_PRIMARY_REPOSITORY_PATH:-.}"
fi
