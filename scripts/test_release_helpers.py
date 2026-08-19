#!/usr/bin/env python3
"""Offline checks for Canvas release helpers. No App Store credentials required."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import app_store_build_preflight as preflight  # noqa: E402


class ReleaseConfigValueTests(unittest.TestCase):
    def test_reads_scalar_from_committed_config(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "release_config_value.py"),
                str(ROOT / "release/release-requirements.json"),
                "bundleIdentifier",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout.strip(), "com.johnhelmuth.canvas")

    def test_rejects_non_scalar_and_missing_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({"nested": {"ok": True}, "list": [1]}), encoding="utf-8")
            missing = subprocess.run(
                [sys.executable, str(SCRIPTS / "release_config_value.py"), str(path), "absent"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(missing.returncode, 0)
            nested = subprocess.run(
                [sys.executable, str(SCRIPTS / "release_config_value.py"), str(path), "list"],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(nested.returncode, 0)


class PreflightHelperTests(unittest.TestCase):
    def test_integer_build_rejects_non_integers(self) -> None:
        self.assertTrue(preflight.INTEGER_BUILD.fullmatch("55"))
        self.assertFalse(preflight.INTEGER_BUILD.fullmatch("55.1"))
        self.assertFalse(preflight.INTEGER_BUILD.fullmatch("1e2"))
        self.assertFalse(preflight.INTEGER_BUILD.fullmatch(""))

    def test_config_string_requires_non_empty_strings(self) -> None:
        self.assertEqual(preflight.config_string({"scheme": "Canvas"}, "scheme"), "Canvas")
        with self.assertRaises(preflight.PreflightError):
            preflight.config_string({"scheme": ""}, "scheme")
        with self.assertRaises(preflight.PreflightError):
            preflight.config_string({"scheme": 26}, "scheme")

    def test_api_url_stays_on_app_store_connect(self) -> None:
        url = preflight.api_url("/v1/builds", {"limit": 200})
        self.assertTrue(url.startswith("https://api.appstoreconnect.apple.com/v1/builds"))

    def test_api_get_rejects_untrusted_hosts(self) -> None:
        with self.assertRaisesRegex(preflight.PreflightError, "untrusted pagination URL"):
            preflight.api_get("https://example.com/v1/builds", "token")

    def test_der_es256_converts_padded_integers(self) -> None:
        r = (b"\x00" + (b"\x01" * 32))[:33]
        s = b"\x02" * 32
        payload = b"\x02" + bytes([len(r)]) + r + b"\x02" + bytes([len(s)]) + s
        der = b"\x30" + bytes([len(payload)]) + payload
        raw = preflight.der_es256_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x01" * 32)
        self.assertEqual(raw[32:], s)

    def test_der_es256_rejects_truncated_input(self) -> None:
        with self.assertRaises(preflight.PreflightError):
            preflight.der_es256_to_raw(b"\x30\x03\x02\x01")


if __name__ == "__main__":
    raise SystemExit(unittest.main())
