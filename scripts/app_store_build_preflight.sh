#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
CONFIG="$ROOT/release/release-requirements.json"

fail() {
  echo "error: App Store build preflight failed: $*" >&2
  exit 1
}

for tool in curl jq openssl python3 xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

: "${ASC_APP_ID:?Set ASC_APP_ID to the numeric App Store Connect app ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID as a secret environment variable}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID as a secret environment variable}"

PROJECT=$(jq -er '.project' "$CONFIG")
SCHEME=$(jq -er '.scheme' "$CONFIG")
PLATFORM=$(jq -er '.platform' "$CONFIG")
cd "$ROOT"

SETTINGS=$(mktemp)
TMP_DIR=$(mktemp -d)
trap 'rm -f "$SETTINGS"; rm -rf "$TMP_DIR"' EXIT HUP INT TERM
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings >"$SETTINGS"

setting() {
  awk -F ' = ' -v key="$1" '$1 ~ ("[[:space:]]" key "$") { print $2; exit }' "$SETTINGS"
}

MARKETING_VERSION=$(setting MARKETING_VERSION)
PROJECT_BUILD=$(setting CURRENT_PROJECT_VERSION)
CANDIDATE_BUILD=${1:-${CI_BUILD_NUMBER:-$PROJECT_BUILD}}

case "$CANDIDATE_BUILD" in *[!0-9]*|'') fail "candidate build number must be an integer; got '$CANDIDATE_BUILD'" ;; esac
case "$ASC_APP_ID" in *[!0-9]*|'') fail "ASC_APP_ID must be the numeric App Store Connect app ID" ;; esac
[ -n "$MARKETING_VERSION" ] || fail "MARKETING_VERSION is empty"

KEY_FILE=${ASC_PRIVATE_KEY_PATH:-}
if [ -z "$KEY_FILE" ]; then
  [ -n "${ASC_PRIVATE_KEY:-}" ] || fail "set secret ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_PATH"
  KEY_FILE="$TMP_DIR/AuthKey.p8"
  printf '%s\n' "$ASC_PRIVATE_KEY" >"$KEY_FILE"
fi
[ -r "$KEY_FILE" ] || fail "App Store Connect private key is not readable"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

NOW=$(date +%s)
EXP=$((NOW + 900))
HEADER=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID")
PAYLOAD=$(jq -cn --arg iss "$ASC_ISSUER_ID" --argjson iat "$NOW" --argjson exp "$EXP"   '{iss:$iss,iat:$iat,exp:$exp,aud:"appstoreconnect-v1"}')
UNSIGNED="$(printf '%s' "$HEADER" | b64url).$(printf '%s' "$PAYLOAD" | b64url)"
printf '%s' "$UNSIGNED" >"$TMP_DIR/unsigned"
openssl dgst -sha256 -sign "$KEY_FILE" -out "$TMP_DIR/signature.der" "$TMP_DIR/unsigned"

SIGNATURE=$(python3 - "$TMP_DIR/signature.der" <<'PY'
import base64
import sys

data = memoryview(open(sys.argv[1], "rb").read())
index = 0

def read_byte():
    global index
    value = data[index]
    index += 1
    return value

def read_length():
    first = read_byte()
    if first < 128:
        return first
    count = first & 0x7f
    value = 0
    for _ in range(count):
        value = (value << 8) | read_byte()
    return value

if read_byte() != 0x30:
    raise SystemExit("invalid ECDSA signature")
read_length()
parts = []
for _ in range(2):
    if read_byte() != 0x02:
        raise SystemExit("invalid ECDSA signature")
    length = read_length()
    value = bytes(data[index:index + length])
    index += length
    value = value.lstrip(b"\x00")
    if len(value) > 32:
        raise SystemExit("invalid ES256 integer")
    parts.append(value.rjust(32, b"\x00"))
print(base64.urlsafe_b64encode(b"".join(parts)).rstrip(b"=").decode())
PY
)
TOKEN="$UNSIGNED.$SIGNATURE"

api_get() {
  url=$1
  output=$2
  status=$(curl --silent --show-error --location     --header "Authorization: Bearer $TOKEN"     --header "Accept: application/vnd.api+json"     --output "$output" --write-out '%{http_code}' "$url")
  case "$status" in 2??) ;; *)
    detail=$(jq -r '.errors[0].detail // .errors[0].title // "unknown App Store Connect error"' "$output" 2>/dev/null || true)
    fail "App Store Connect returned HTTP $status: $detail"
  esac
}

PRERELEASE_URL=$(printf 'https://api.appstoreconnect.apple.com/v1/preReleaseVersions?filter%%5Bapp%%5D=%s&filter%%5Bplatform%%5D=%s&filter%%5Bversion%%5D=%s&limit=10'   "$ASC_APP_ID" "$PLATFORM" "$MARKETING_VERSION")
api_get "$PRERELEASE_URL" "$TMP_DIR/prerelease.json"
PRERELEASE_COUNT=$(jq '.data | length' "$TMP_DIR/prerelease.json")
[ "$PRERELEASE_COUNT" -le 1 ] || fail "multiple App Store Connect prerelease versions matched $MARKETING_VERSION/$PLATFORM"
PRERELEASE_ID=$(jq -r '.data[0].id // empty' "$TMP_DIR/prerelease.json")

LATEST_BUILD=0
if [ -n "$PRERELEASE_ID" ]; then
  NEXT_URL=$(printf 'https://api.appstoreconnect.apple.com/v1/builds?filter%%5BpreReleaseVersion%%5D=%s&limit=200' "$PRERELEASE_ID")
  PAGE=0
  while [ -n "$NEXT_URL" ]; do
    PAGE=$((PAGE + 1))
    api_get "$NEXT_URL" "$TMP_DIR/builds-$PAGE.json"
    NON_INTEGER=$(jq '[.data[].attributes.version | select(test("^[0-9]+$") | not)] | length' "$TMP_DIR/builds-$PAGE.json")
    [ "$NON_INTEGER" -eq 0 ] || fail "App Store Connect contains non-integer build versions for $MARKETING_VERSION; compare them manually"
    PAGE_MAX=$(jq '[.data[].attributes.version | tonumber] | max // 0' "$TMP_DIR/builds-$PAGE.json")
    [ "$PAGE_MAX" -le "$LATEST_BUILD" ] || LATEST_BUILD=$PAGE_MAX
    NEXT_URL=$(jq -r '.links.next // empty' "$TMP_DIR/builds-$PAGE.json")
  done
fi

REQUIRED_NEXT=$((LATEST_BUILD + 1))
if [ "$CANDIDATE_BUILD" -le "$LATEST_BUILD" ]; then
  fail "candidate $MARKETING_VERSION ($CANDIDATE_BUILD) collides with uploaded builds; use build $REQUIRED_NEXT or greater"
fi

echo "App Store build preflight OK: $MARKETING_VERSION ($CANDIDATE_BUILD); latest uploaded is $LATEST_BUILD, next available is $REQUIRED_NEXT"
