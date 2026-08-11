#!/usr/bin/env python3
"""Extract one public version section from CHANGELOG.md for GitHub Release."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def extract_release_notes(changelog: str, version: str) -> str:
    normalized = version.removeprefix("v").strip()
    if not normalized or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", normalized):
        raise ValueError(f"invalid release version: {version!r}")

    heading = re.compile(rf"^##[ \t]+v?{re.escape(normalized)}[ \t]*$", re.MULTILINE)
    match = heading.search(changelog)
    if match is None:
        raise ValueError(f"CHANGELOG.md has no section for {normalized}")

    next_heading = re.search(r"^##[ \t]+", changelog[match.end() :], re.MULTILINE)
    end = match.end() + next_heading.start() if next_heading else len(changelog)
    body = changelog[match.end() : end].strip()
    if not body:
        raise ValueError(f"CHANGELOG.md section {normalized} is empty")

    return (
        f"## Что изменилось в {normalized}\n\n"
        f"{body}\n\n"
        "---\n"
        "Полная история: [CHANGELOG.md]"
        "(https://github.com/PastFly/Selective-Remote/blob/main/CHANGELOG.md)\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create GitHub Release notes from a CHANGELOG.md section."
    )
    parser.add_argument("version", help="Public version, for example 0.19.0 or v0.19.0")
    parser.add_argument(
        "--changelog",
        default="CHANGELOG.md",
        type=Path,
        help="Path to CHANGELOG.md (default: ./CHANGELOG.md)",
    )
    args = parser.parse_args()

    try:
        changelog = args.changelog.read_text(encoding="utf-8")
        notes = extract_release_notes(changelog, args.version)
    except (OSError, ValueError) as error:
        print(f"release_notes.py: {error}", file=sys.stderr)
        return 1

    sys.stdout.write(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
