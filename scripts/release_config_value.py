#!/usr/bin/env python3
"""Read one scalar value from the repository release configuration."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: release_config_value.py CONFIG KEY", file=sys.stderr)
        return 2

    config_path = Path(sys.argv[1])
    key = sys.argv[2]

    try:
        value: object = json.loads(config_path.read_text(encoding="utf-8"))
        for component in key.split("."):
            if not isinstance(value, dict) or component not in value:
                raise KeyError(key)
            value = value[component]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"error: cannot read release config value {key!r}: {error}", file=sys.stderr)
        return 1

    if isinstance(value, bool):
        output = "true" if value else "false"
    elif isinstance(value, (str, int, float)):
        output = str(value)
    else:
        print(f"error: release config value {key!r} is not a scalar", file=sys.stderr)
        return 1

    if "\x00" in output or "\n" in output or "\r" in output:
        print(f"error: release config value {key!r} contains an invalid control character", file=sys.stderr)
        return 1

    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
