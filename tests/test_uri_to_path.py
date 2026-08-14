#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Glen Pridgen
"""URI to POSIX path rules used by lua/extensions/video_tags.lua."""

import re
import unittest
from pathlib import Path

LUA = Path(__file__).resolve().parents[1] / "lua" / "extensions" / "video_tags.lua"


def decode_uri(uri):
    return re.sub(
        r"%([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), uri
    )


def uri_to_path(uri):
    if not uri:
        return None
    decoded = decode_uri(uri)
    decoded = re.sub(r"^file://localhost", "", decoded)
    decoded = re.sub(r"^file://", "", decoded)
    if not decoded.startswith("/"):
        return None
    return decoded


class UriToPathTests(unittest.TestCase):
    def test_standard_file_uri(self):
        self.assertEqual(
            uri_to_path("file:///Users/glen/clip.mov"),
            "/Users/glen/clip.mov",
        )

    def test_percent_encoded_spaces(self):
        self.assertEqual(
            uri_to_path("file:///Users/glen/My%20Video.mp4"),
            "/Users/glen/My Video.mp4",
        )

    def test_localhost_prefix(self):
        self.assertEqual(
            uri_to_path("file://localhost/Users/glen/clip.mov"),
            "/Users/glen/clip.mov",
        )

    def test_http_is_rejected(self):
        self.assertIsNone(uri_to_path("http://example.com/a.mp4"))

    def test_empty_is_rejected(self):
        self.assertIsNone(uri_to_path(""))
        self.assertIsNone(uri_to_path(None))

    def test_lua_extension_implements_the_same_rules(self):
        source = LUA.read_text()
        self.assertIn('string.gsub(decoded, "^file://localhost", "")', source)
        self.assertIn('string.gsub(decoded, "^file://", "")', source)
        self.assertIn("%%(%x%x)", source)


if __name__ == "__main__":
    unittest.main()
