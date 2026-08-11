#!/usr/bin/env python3
"""Fail if any SPM checkout needs a newer Swift than CI guarantees."""

from __future__ import annotations

import pathlib
import re
import sys

MIN_MAJOR = int(sys.argv[1]) if len(sys.argv) > 1 else 6
MIN_MINOR = int(sys.argv[2]) if len(sys.argv) > 2 else 2


def main() -> int:
    checkouts = pathlib.Path(".build/checkouts")
    if not checkouts.is_dir():
        print("No .build/checkouts directory; run swift package resolve first.", file=sys.stderr)
        return 1

    max_pair = (0, 0)
    for pkg in sorted(p for p in checkouts.iterdir() if p.is_dir()):
        manifest = pkg / "Package.swift"
        if not manifest.is_file():
            continue
        lines = manifest.read_text(encoding="utf-8", errors="replace").splitlines()
        if not lines:
            continue
        match = re.search(r"swift-tools-version:\s*([0-9]+)\.([0-9]+)", lines[0])
        if not match:
            continue
        pair = (int(match.group(1)), int(match.group(2)))
        print(f"{pkg.name}: Swift tools {pair[0]}.{pair[1]}")
        max_pair = max(max_pair, pair)

    print(f"Max dependency tools version: {max_pair[0]}.{max_pair[1]}")
    print(f"CI minimum Swift: {MIN_MAJOR}.{MIN_MINOR}")
    if max_pair > (MIN_MAJOR, MIN_MINOR):
        print(
            f"Dependency requires Swift tools {max_pair[0]}.{max_pair[1]}, "
            f"but CI only guarantees {MIN_MAJOR}.{MIN_MINOR}. "
            "Raise LISTEN_TO_ME_MIN_SWIFT_* in Scripts/select-ci-xcode.sh "
            "and confirm the GitHub runner has that Xcode.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
