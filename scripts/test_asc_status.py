#!/usr/bin/env python3
"""Offline checks for Linux App Store Connect helpers."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_ship  # noqa: E402
import asc_status as status  # noqa: E402


class MissingCredentialsTests(unittest.TestCase):
    def test_lists_required_names(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            missing = status.missing_credentials()
        self.assertIn("ASC_ISSUER_ID", missing)
        self.assertIn("ASC_KEY_ID", missing)
        self.assertIn("ASC_PRIVATE_KEY", missing)

    def test_accepts_key_path_instead_of_pem(self) -> None:
        with mock.patch.dict(
            os.environ,
            {
                "ASC_ISSUER_ID": "iss",
                "ASC_KEY_ID": "kid",
                "ASC_PRIVATE_KEY_PATH": "/tmp/key.p8",
            },
            clear=True,
        ):
            self.assertEqual(status.missing_credentials(), [])


class MarketingVersionTests(unittest.TestCase):
    def test_reads_pbxproj(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "project.pbxproj"
            path.write_text("MARKETING_VERSION = 1.4.13;\n", encoding="utf-8")
            self.assertEqual(asc_ship.marketing_version(Path(directory)), "1.4.13")

    def test_reads_gardeniq_plist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            path.write_text(
                "<key>CFBundleShortVersionString</key>\n\t<string>1.4.4</string>\n",
                encoding="utf-8",
            )
            self.assertEqual(asc_ship.marketing_version(Path(directory)), "1.4.4")


if __name__ == "__main__":
    unittest.main()
