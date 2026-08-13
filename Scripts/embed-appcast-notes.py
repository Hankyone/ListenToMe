#!/usr/bin/env python3
"""Ensure appcast release notes are inline markdown (not HTML / remote URL).

Sparkle renders HTML descriptions in WKWebView, which cold-starts slowly and
shows a spinner. Markdown/plain-text use NSTextView and appear immediately.

Only the section for the appcast item's short version is embedded. The full
RELEASE_NOTES.md history must not appear in the update alert.
"""

from __future__ import annotations

import pathlib
import re
import sys
import tempfile
import unittest


SHORT_VERSION_RE = re.compile(
    r"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"
)


def short_version_from_appcast(appcast: str) -> str:
    match = SHORT_VERSION_RE.search(appcast)
    if not match:
        raise SystemExit("appcast.xml is missing sparkle:shortVersionString")
    version = match.group(1).strip()
    if not version:
        raise SystemExit("appcast.xml has an empty sparkle:shortVersionString")
    return version


def notes_for_version(notes_md: str, version: str) -> str:
    heading = re.compile(
        rf"^## ListenToMe {re.escape(version)}\s*$",
        re.MULTILINE,
    )
    match = heading.search(notes_md)
    if not match:
        raise SystemExit(
            f"RELEASE_NOTES.md has no '## ListenToMe {version}' section"
        )
    rest = notes_md[match.end() :]
    next_heading = re.search(r"^## ", rest, flags=re.MULTILINE)
    body = rest[: next_heading.start()] if next_heading else rest
    body = body.strip()
    if not body:
        raise SystemExit(
            f"RELEASE_NOTES.md section ListenToMe {version} is empty"
        )
    return body + "\n"


def embed_notes(appcast_path: pathlib.Path, notes_path: pathlib.Path) -> None:
    appcast = appcast_path.read_text(encoding="utf-8")
    version = short_version_from_appcast(appcast)
    notes_md = notes_for_version(
        notes_path.read_text(encoding="utf-8"),
        version,
    )

    # Never leave a remote notes URL — that forces another network round-trip.
    appcast = re.sub(
        r"[ \t]*<sparkle:releaseNotesLink\b.*?</sparkle:releaseNotesLink>\n?",
        "",
        appcast,
        flags=re.DOTALL,
    )
    appcast = re.sub(
        r"[ \t]*<description\b.*?</description>\n?",
        "",
        appcast,
        flags=re.DOTALL,
    )

    match = re.search(r"^([ \t]*)<enclosure\b", appcast, flags=re.MULTILINE)
    if not match:
        raise SystemExit("appcast.xml is missing an enclosure element")

    indent = match.group(1)
    # sparkle:format="markdown" → SUTextViewReleaseNotesView (no WKWebView).
    description = (
        f'{indent}<description sparkle:format="markdown"><![CDATA[\n'
        f"{notes_md}"
        f"{indent}]]></description>\n"
    )
    appcast = appcast[: match.start()] + description + appcast[match.start() :]
    appcast_path.write_text(appcast, encoding="utf-8")


class EmbedAppcastNotesTests(unittest.TestCase):
    def test_keeps_only_the_matching_version_section(self) -> None:
        notes = (
            "## ListenToMe 0.3.56\n"
            "\n"
            "- newest\n"
            "\n"
            "## ListenToMe 0.3.55\n"
            "\n"
            "- older\n"
        )
        self.assertEqual(notes_for_version(notes, "0.3.56"), "- newest\n")
        self.assertEqual(notes_for_version(notes, "0.3.55"), "- older\n")

    def test_does_not_match_a_prefix_version(self) -> None:
        notes = (
            "## ListenToMe 0.3.56\n"
            "\n"
            "- newest\n"
            "\n"
            "## ListenToMe 0.3.5\n"
            "\n"
            "- unrelated\n"
        )
        self.assertEqual(notes_for_version(notes, "0.3.5"), "- unrelated\n")

    def test_embed_rewrites_description_to_one_version(self) -> None:
        appcast = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <sparkle:shortVersionString>0.3.56</sparkle:shortVersionString>
            <description sparkle:format="markdown"><![CDATA[
## ListenToMe 0.3.56

- newest

## ListenToMe 0.3.55

- older
            ]]></description>
            <enclosure url="https://example.com/ListenToMe-0.3.56.zip" length="1" type="application/octet-stream"/>
        </item>
    </channel>
</rss>
"""
        notes = (
            "## ListenToMe 0.3.56\n"
            "\n"
            "- newest\n"
            "\n"
            "## ListenToMe 0.3.55\n"
            "\n"
            "- older\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            appcast_path = root / "appcast.xml"
            notes_path = root / "RELEASE_NOTES.md"
            appcast_path.write_text(appcast, encoding="utf-8")
            notes_path.write_text(notes, encoding="utf-8")
            embed_notes(appcast_path, notes_path)
            written = appcast_path.read_text(encoding="utf-8")
        self.assertIn("- newest", written)
        self.assertNotIn("0.3.55", written)
        self.assertNotIn("- older", written)
        self.assertIn('sparkle:format="markdown"', written)


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] in {"--self-test", "test"}:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(
            EmbedAppcastNotesTests
        )
        result = unittest.TextTestRunner(verbosity=1).run(suite)
        return 0 if result.wasSuccessful() else 1
    if len(sys.argv) == 4 and sys.argv[1] == "--extract":
        version = sys.argv[2]
        notes_path = pathlib.Path(sys.argv[3])
        sys.stdout.write(
            notes_for_version(notes_path.read_text(encoding="utf-8"), version)
        )
        return 0
    if len(sys.argv) != 3:
        print(
            "Usage: embed-appcast-notes.py <appcast.xml> <notes.md>\n"
            "       embed-appcast-notes.py --extract <version> <notes.md>\n"
            "       embed-appcast-notes.py --self-test",
            file=sys.stderr,
        )
        return 2
    embed_notes(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
