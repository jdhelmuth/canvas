#!/usr/bin/env python3
"""Offline checks for Linux App Store Connect status helper."""

from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
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


if __name__ == "__main__":
    unittest.main()
