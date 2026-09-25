#!/usr/bin/env python3
"""Render release notes from the approved versioned source."""

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


def extract_detailed_032_notes(source: str) -> str:
    ru = "## FINAL_DETAILED_RELEASE_NOTES_RU\n"
    en = "## FINAL_DETAILED_RELEASE_NOTES_EN\n"
    end = "## SHORT_GITHUB_RELEASE_NOTES_RU\n"
    if source.count(ru) != 1 or source.count(en) != 1 or source.count(end) != 1:
        raise ValueError("0.32.0 detailed RU/EN release notes are missing or duplicated")
    ru_start = source.index(ru)
    en_start = source.index(en)
    end_start = source.index(end)
    if not ru_start < en_start < end_start:
        raise ValueError("0.32.0 detailed release notes have invalid order")
    ru_body = source[ru_start + len(ru) : en_start].strip()
    en_body = source[en_start + len(en) : end_start].strip()
    if not ru_body or not en_body:
        raise ValueError("0.32.0 detailed RU/EN release notes are empty")
    return f"## Что нового в 0.32.0\n\n{ru_body}\n\n## What's new in 0.32.0\n\n{en_body}\n"


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
        normalized = args.version.removeprefix("v").strip()
        if normalized == "0.32.0":
            source = Path("releases/0.32.0-notes.md").read_text(encoding="utf-8")
            notes = extract_detailed_032_notes(source)
        else:
            changelog = args.changelog.read_text(encoding="utf-8")
            notes = extract_release_notes(changelog, args.version)
    except (OSError, ValueError) as error:
        print(f"release_notes.py: {error}", file=sys.stderr)
        return 1

    sys.stdout.write(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
