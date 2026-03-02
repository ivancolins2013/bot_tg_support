#!/usr/bin/env python3
"""Check text files for UTF-8 decode errors and common mojibake artifacts."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import argparse
import sys


TEXT_EXTENSIONS = {
    ".py",
    ".env",
    ".sql",
    ".txt",
    ".md",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
}

EXCLUDED_DIRS = {
    ".venv",
    ".git",
    "__pycache__",
}

# Characters that usually appear when UTF-8 text was decoded with cp1251/cp866.
SUSPICIOUS_CHARS = {
    "\u0402",  # CYRILLIC CAPITAL LETTER DJE
    "\u0452",  # CYRILLIC SMALL LETTER DJE
    "\u0409",  # CYRILLIC CAPITAL LETTER LJE
    "\u0459",  # CYRILLIC SMALL LETTER LJE
    "\u040A",  # CYRILLIC CAPITAL LETTER NJE
    "\u045A",  # CYRILLIC SMALL LETTER NJE
    "\u040E",  # CYRILLIC CAPITAL LETTER SHORT U
    "\u045E",  # CYRILLIC SMALL LETTER SHORT U
    "\u040F",  # CYRILLIC CAPITAL LETTER DZHE
    "\u045F",  # CYRILLIC SMALL LETTER DZHE
}


@dataclass
class Issue:
    path: Path
    kind: str
    details: str


def should_scan(path: Path) -> bool:
    if path.suffix.lower() not in TEXT_EXTENSIONS:
        return False
    return not any(part in EXCLUDED_DIRS for part in path.parts)


def scan_file(path: Path) -> list[Issue]:
    issues: list[Issue] = []
    raw = path.read_bytes()

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        issues.append(
            Issue(
                path=path,
                kind="decode_error",
                details=f"UTF-8 decode failed at byte {exc.start}: {exc.reason}",
            )
        )
        return issues

    if "\ufffd" in text:
        issues.append(
            Issue(
                path=path,
                kind="replacement_char",
                details="Contains replacement symbol U+FFFD.",
            )
        )

    suspicious_count = sum(1 for ch in text if ch in SUSPICIOUS_CHARS)
    if suspicious_count > 0:
        issues.append(
            Issue(
                path=path,
                kind="suspicious_chars",
                details=f"Contains {suspicious_count} suspicious mojibake characters.",
            )
        )

    return issues


def iter_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file() and should_scan(p))


def main() -> int:
    parser = argparse.ArgumentParser(description="Check project files for encoding problems.")
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="Root path to scan (default: current directory).",
    )
    args = parser.parse_args()

    root = Path(args.path).resolve()
    if not root.exists():
        print(f"[error] Path does not exist: {root}")
        return 2

    targets = [root] if root.is_file() else iter_files(root)
    all_issues: list[Issue] = []

    for target in targets:
        if target.is_file():
            if should_scan(target):
                all_issues.extend(scan_file(target))
            continue
        all_issues.extend(scan_file(target))

    if not all_issues:
        print(f"[ok] Encoding check passed. Scanned {len(targets)} file(s).")
        return 0

    print(f"[fail] Found {len(all_issues)} issue(s):")
    for issue in all_issues:
        rel = issue.path.relative_to(root) if issue.path.is_relative_to(root) else issue.path
        print(f"  - {rel}: {issue.kind} -> {issue.details}")

    return 1


if __name__ == "__main__":
    sys.exit(main())
