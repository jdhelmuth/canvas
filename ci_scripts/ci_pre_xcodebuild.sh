#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
"$ROOT/scripts/validate_release_requirements.sh"

if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
  "$ROOT/scripts/app_store_build_preflight.sh"
fi
