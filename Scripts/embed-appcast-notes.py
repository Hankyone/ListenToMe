#!/usr/bin/env python3
"""Ensure appcast release notes are inline markdown (not HTML / remote URL).

Sparkle renders HTML descriptions in WKWebView, which cold-starts slowly and
shows a spinner. Markdown/plain-text use NSTextView and appear immediately.
"""

from __future__ import annotations

import pathlib
import re
import sys


def embed_notes(appcast_path: pathlib.Path, notes_path: pathlib.Path) -> None:
    appcast = appcast_path.read_text(encoding="utf-8")
    notes_md = notes_path.read_text(encoding="utf-8").strip() + "\n"

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


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: embed-appcast-notes.py <appcast.xml> <notes.md>",
            file=sys.stderr,
        )
        return 2
    embed_notes(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
