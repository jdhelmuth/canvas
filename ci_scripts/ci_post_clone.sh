#!/bin/sh
set -eu

ROOT="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is required}"
"$ROOT/scripts/validate_release_requirements.sh"
