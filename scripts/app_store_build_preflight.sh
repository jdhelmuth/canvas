#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"

command -v python3 >/dev/null 2>&1 || {
  echo "error: App Store build preflight failed: missing required tool: python3" >&2
  exit 1
}

exec python3 "$ROOT/scripts/app_store_build_preflight.py" "$@"
