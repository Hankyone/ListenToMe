#!/usr/bin/env python3
"""Replace em-dash update copy inside Sparkle.framework localizations.

Sparkle looks up strings by the English template key from its own bundle.
Keep keys intact and rewrite values so the UI no longer shows em dashes.
"""

from __future__ import annotations

import pathlib
import plistlib
import sys

# Values in Base.lproj already use positional formatters (%1$@…); keys keep %@ .
VALUE_REPLACEMENTS = {
    "%1$@ %2$@ is now available—you have %3$@. Would you like to download it now?":
        "%1$@ %2$@ is now available. You have %3$@. Would you like to download it now?",
    "%1$@ %2$@ is now available—you have %3$@. This is an important update; would you like to download it now?":
        "%1$@ %2$@ is now available. You have %3$@. This is an important update; would you like to download it now?",
    "%1$@ %2$@ is now available—you have %3$@. Would you like to learn more about this update on the web?":
        "%1$@ %2$@ is now available. You have %3$@. Would you like to learn more about this update on the web?",
    # Fallback if a locale still uses non-positional placeholders in the value.
    "%@ %@ is now available—you have %@. Would you like to download it now?":
        "%1$@ %2$@ is now available. You have %3$@. Would you like to download it now?",
    "%@ %@ is now available—you have %@. This is an important update; would you like to download it now?":
        "%1$@ %2$@ is now available. You have %3$@. This is an important update; would you like to download it now?",
    "%@ %@ is now available—you have %@. Would you like to learn more about this update on the web?":
        "%1$@ %2$@ is now available. You have %3$@. Would you like to learn more about this update on the web?",
}


def rewrite_value(value: str) -> str:
    if value in VALUE_REPLACEMENTS:
        return VALUE_REPLACEMENTS[value]
    if "—" not in value:
        return value
    # Preserve meaning for translated locales: break the em dash into a period.
    return value.replace("—", ". ").replace("  ", " ")


def patch_strings_file(path: pathlib.Path) -> bool:
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
    except Exception:
        return False

    changed = False
    for key, value in list(data.items()):
        if not isinstance(value, str):
            continue
        new_value = rewrite_value(value)
        if new_value != value:
            data[key] = new_value
            changed = True

    if not changed:
        return False

    with path.open("wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: patch-sparkle-strings.py <Sparkle.framework>", file=sys.stderr)
        return 2

    framework = pathlib.Path(sys.argv[1])
    resources = framework / "Versions" / "B" / "Resources"
    if not resources.is_dir():
        resources = framework / "Resources"
    if not resources.is_dir():
        print(f"No Resources directory in {framework}", file=sys.stderr)
        return 1

    patched = 0
    for strings_path in resources.rglob("Sparkle.strings"):
        if patch_strings_file(strings_path):
            patched += 1
            print(f"patched {strings_path.relative_to(framework)}")

    if patched == 0:
        print("No Sparkle.strings files needed patching (or none found).", file=sys.stderr)
        return 1
    print(f"Patched {patched} Sparkle.strings file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
