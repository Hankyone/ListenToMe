#!/usr/bin/env python3
"""Embed release notes into appcast.xml and drop external releaseNotesLink."""

from __future__ import annotations

import html
import pathlib
import re
import sys


def markdown_to_simple_html(markdown: str) -> str:
    lines = markdown.replace("\r\n", "\n").split("\n")
    parts: list[str] = [
        '<div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;'
        'font-size:13px;line-height:1.45;">'
    ]
    in_list = False

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            parts.append("</ul>")
            in_list = False

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            close_list()
            continue

        if line.startswith("## "):
            close_list()
            parts.append(f"<h2>{html.escape(line[3:].strip())}</h2>")
            continue
        if line.startswith("# "):
            close_list()
            parts.append(f"<h1>{html.escape(line[2:].strip())}</h1>")
            continue
        if line.startswith("- "):
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{html.escape(line[2:].strip())}</li>")
            continue

        close_list()
        parts.append(f"<p>{html.escape(line.strip())}</p>")

    close_list()
    parts.append("</div>")
    return "\n".join(parts)


def embed_notes(appcast_path: pathlib.Path, notes_path: pathlib.Path) -> None:
    appcast = appcast_path.read_text(encoding="utf-8")
    notes_html = markdown_to_simple_html(notes_path.read_text(encoding="utf-8"))

    # Prefer inline HTML so Sparkle never has to fetch a separate notes URL.
    appcast = re.sub(
        r"[ \t]*<sparkle:releaseNotesLink>.*?</sparkle:releaseNotesLink>\n?",
        "",
        appcast,
        flags=re.DOTALL,
    )
    appcast = re.sub(
        r"[ \t]*<description>.*?</description>\n?",
        "",
        appcast,
        flags=re.DOTALL,
    )

    match = re.search(r"^([ \t]*)<enclosure\b", appcast, flags=re.MULTILINE)
    if not match:
        raise SystemExit("appcast.xml is missing an enclosure element")

    indent = match.group(1)
    description = (
        f"{indent}<description><![CDATA[\n"
        f"{notes_html}\n"
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
