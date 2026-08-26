#!/usr/bin/env python3
"""Validate DawnShell Markdown navigation without network access."""

from __future__ import annotations

import html
import pathlib
import re
import sys
import urllib.parse


REPO = pathlib.Path(__file__).resolve().parent.parent
DOCS = REPO / "docs"
ROOT_README = REPO / "README.md"
ROOT_README_KO = REPO / "README.ko.md"
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)|!\[[^\]]*\]\(([^)]+)\)")
HEADING_RE = re.compile(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$")
EXTERNAL_SCHEMES = {"http", "https", "mailto", "tel", "data"}


def markdown_files() -> list[pathlib.Path]:
    roots = [
        ROOT_README,
        ROOT_README_KO,
        REPO / "LICENSES" / "README.md",
        REPO / "LICENSES" / "ANDROID_DEPENDENCIES.md",
    ]
    roots.extend(sorted(DOCS.glob("*.md")))
    roots.extend(sorted((REPO / "bfu-runtime").glob("*.md")))
    roots.extend(sorted((REPO / "bfu-runtime" / "dropbear").glob("*.md")))
    return roots


def without_fenced_code(text: str) -> str:
    result: list[str] = []
    fence: str | None = None
    for line in text.splitlines():
        marker = re.match(r"^\s*(```+|~~~+)", line)
        if marker:
            current = marker.group(1)[0]
            if fence is None:
                fence = current
            elif fence == current:
                fence = None
            result.append("")
        elif fence is None:
            result.append(line)
        else:
            result.append("")
    return "\n".join(result)


def github_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", html.unescape(value)).strip().lower()
    value = re.sub(r"[`*_~]", "", value)
    value = "".join(
        character
        for character in value
        if character.isalnum()
        or character in {"_", "-", " "}
    )
    return re.sub(r"\s+", "-", value).strip("-")


def anchors(path: pathlib.Path) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    text = without_fenced_code(path.read_text(encoding="utf-8"))
    for line in text.splitlines():
        match = HEADING_RE.match(line)
        if not match:
            continue
        base = github_slug(match.group(1))
        count = counts.get(base, 0)
        counts[base] = count + 1
        found.add(base if count == 0 else f"{base}-{count}")
    return found


def raw_links(path: pathlib.Path) -> list[str]:
    text = without_fenced_code(path.read_text(encoding="utf-8"))
    return [next(group for group in match.groups() if group is not None).strip()
            for match in LINK_RE.finditer(text)]


def split_target(raw: str) -> tuple[str, str]:
    if raw.startswith("<") and raw.endswith(">"):
        raw = raw[1:-1]
    path_part, separator, fragment = raw.partition("#")
    path_part = path_part.split("?", 1)[0]
    decoded_path = urllib.parse.unquote(path_part) if "%" in path_part else path_part
    decoded_fragment = fragment if separator else ""
    if "%" in decoded_fragment:
        decoded_fragment = urllib.parse.unquote(decoded_fragment)
    return decoded_path, decoded_fragment


def validate_links(files: list[pathlib.Path]) -> list[str]:
    errors: list[str] = []
    anchor_cache: dict[pathlib.Path, set[str]] = {}
    repo_resolved = REPO.resolve()
    for source in files:
        for raw in raw_links(source):
            parsed = urllib.parse.urlsplit(raw)
            if parsed.scheme.lower() in EXTERNAL_SCHEMES or raw.startswith("//"):
                continue
            path_part, fragment = split_target(raw)
            target = source if not path_part else (source.parent / path_part)
            target = target.resolve()
            try:
                target.relative_to(repo_resolved)
            except ValueError:
                errors.append(f"{source.relative_to(REPO)}: link escapes repository: {raw}")
                continue
            if not target.exists():
                errors.append(f"{source.relative_to(REPO)}: missing target: {raw}")
                continue
            if fragment and target.suffix.lower() == ".md":
                available = anchor_cache.setdefault(target, anchors(target))
                if fragment not in available:
                    errors.append(
                        f"{source.relative_to(REPO)}: missing heading '#{fragment}' in "
                        f"{target.relative_to(REPO)}"
                    )
    return errors


def validate_language_pairs() -> list[str]:
    errors: list[str] = []
    for english in sorted(DOCS.glob("*.md")):
        if english.name.endswith(".ko.md"):
            continue
        korean = english.with_name(f"{english.stem}.ko.md")
        if not korean.exists():
            errors.append(f"docs/{english.name}: missing Korean counterpart")
            continue
        if korean.name not in raw_links(english):
            errors.append(f"docs/{english.name}: missing language link to {korean.name}")
        if english.name not in raw_links(korean):
            errors.append(f"docs/{korean.name}: missing language link to {english.name}")
    for korean in sorted(DOCS.glob("*.ko.md")):
        english = korean.with_name(korean.name.replace(".ko.md", ".md"))
        if not english.exists():
            errors.append(f"docs/{korean.name}: missing English counterpart")
    return errors


def validate_root_indexes() -> list[str]:
    errors: list[str] = []
    english_links = set(raw_links(ROOT_README))
    korean_links = set(raw_links(ROOT_README_KO))
    for path in sorted(DOCS.glob("*.md")):
        relative = f"docs/{path.name}"
        if path.name.endswith(".ko.md"):
            if relative not in korean_links:
                errors.append(f"README.ko.md: missing documentation link: {relative}")
        elif relative not in english_links:
            errors.append(f"README.md: missing documentation link: {relative}")
    return errors


def validate_basic_structure(files: list[pathlib.Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        text = path.read_text(encoding="utf-8")
        if not text.endswith("\n"):
            errors.append(f"{path.relative_to(REPO)}: missing final newline")
        first_content = next((line for line in text.splitlines() if line.strip()), "")
        if not first_content.startswith("# "):
            errors.append(f"{path.relative_to(REPO)}: first content must be one H1")
    return errors


def main() -> int:
    files = markdown_files()
    errors = []
    errors.extend(validate_basic_structure(files))
    errors.extend(validate_links(files))
    errors.extend(validate_language_pairs())
    errors.extend(validate_root_indexes())
    if errors:
        print("Documentation validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        f"Documentation validation passed: {len(files)} Markdown files, "
        f"{len(list(DOCS.glob('*.md')))} indexed docs pages."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
