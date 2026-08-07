from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


IPYNB_ROOT = Path(__file__).resolve().parent
SOURCE_ROOT = IPYNB_ROOT.parent
CODE_PATTERN = re.compile(
    r"(?P<fence>~~~|\x60{3})python[^\n]*\n(?P<body>.*?)(?:\n(?P=fence))",
    re.DOTALL,
)
IMAGE_PATTERN = re.compile(r"!\[[^\]]*\]\((?P<path>[^)\s]+)")
HTML_IMAGE_PATTERN = re.compile(
    r"<img\b[^>]*\bsrc=[\"'](?P<path>[^\"']+)[\"']",
    re.IGNORECASE,
)
ANCHOR_PATTERN = re.compile(r"\{#([^}]+)\}")
DISPLAY_MATH_PATTERN = re.compile(r"\$\$(.*?)\$\$", re.DOTALL)
HEADING_PATTERN = re.compile(r"^(#{2,6})\s+", re.MULTILINE)
TABLE_SEPARATOR_PATTERN = re.compile(
    r"^\s*\|(?:\s*:?-{3,}:?\s*\|)+\s*$",
    re.MULTILINE,
)


def source_text(cell: dict) -> str:
    source = cell.get("source", "")
    return "".join(source) if isinstance(source, list) else str(source)


def read_notebook(path: Path) -> tuple[dict, str]:
    notebook = json.loads(path.read_text(encoding="utf-8"))
    cells = notebook.get("cells", [])
    if not cells:
        raise AssertionError(f"{path}: notebook has no cells")

    first = cells[0]
    yaml = source_text(first)
    if first.get("cell_type") != "raw" or not yaml.lstrip().startswith("---"):
        raise AssertionError(f"{path}: first cell must be raw YAML")
    if yaml.strip().count("---") < 2:
        raise AssertionError(f"{path}: incomplete YAML front matter")

    title_match = re.search(r"^title:\s*(.+?)\s*$", yaml, re.MULTILINE)
    if not title_match:
        raise AssertionError(f"{path}: YAML title is missing")
    title = title_match.group(1).strip()
    if ":" in title and not (
        (title.startswith('"') and title.endswith('"'))
        or (title.startswith("'") and title.endswith("'"))
    ):
        raise AssertionError(f"{path}: YAML title containing ':' must be quoted")

    body = "\n\n".join(
        source_text(cell)
        for cell in cells[1:]
        if cell.get("cell_type") in {"markdown", "raw"}
    )
    markdown_without_code = CODE_PATTERN.sub("", body)
    if re.search(r"^\s*#(?!#)\s+\S", markdown_without_code, re.MULTILINE):
        raise AssertionError(f"{path}: duplicate Markdown H1 found below YAML title")
    return notebook, body


def code_blocks(text: str) -> list[str]:
    return [match.group("body") for match in CODE_PATTERN.finditer(text)]


def image_paths(text: str) -> list[str]:
    paths = [match.group("path") for match in IMAGE_PATTERN.finditer(text)]
    paths.extend(match.group("path") for match in HTML_IMAGE_PATTERN.finditer(text))
    return paths


def local_source_asset(notebook: Path, reference: str) -> Path | None:
    parsed = urlsplit(reference)
    if parsed.scheme or parsed.netloc or reference.startswith(("/", "#", "data:")):
        return None
    clean = unquote(parsed.path)
    if not clean:
        return None
    return (notebook.parent / clean).resolve()


def validate_source(
    english_path: Path,
    chinese_path: Path | None,
    execute_code: bool,
) -> dict[str, int | bool]:
    english_notebook, english = read_notebook(english_path)
    blocks = code_blocks(english)
    anchors = ANCHOR_PATTERN.findall(english)
    images = image_paths(english)

    if len(anchors) != len(set(anchors)):
        raise AssertionError(f"{english_path}: duplicate heading anchors found")

    for reference in images:
        if urlsplit(reference).scheme in {"http", "https"}:
            raise AssertionError(
                f"{english_path}: remote images are not allowed: {reference}"
            )
        target = local_source_asset(english_path, reference)
        if target is not None and not target.is_file():
            raise AssertionError(f"{english_path}: missing local image {reference}")

    if execute_code:
        previous_backend = os.environ.get("MPLBACKEND")
        os.environ["MPLBACKEND"] = "Agg"
        namespace: dict[str, object] = {"__name__": "__main__"}
        try:
            for index, block in enumerate(blocks, start=1):
                output = io.StringIO()
                try:
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                        exec(
                            compile(block, f"{english_path.name}:example-{index}", "exec"),
                            namespace,
                        )
                except Exception as error:
                    captured = output.getvalue()[-2000:]
                    raise AssertionError(
                        f"{english_path}: code example {index} failed: {error}\n{captured}"
                    ) from error
        finally:
            if previous_backend is None:
                os.environ.pop("MPLBACKEND", None)
            else:
                os.environ["MPLBACKEND"] = previous_backend

    bilingual = chinese_path is not None
    if chinese_path is not None:
        chinese_notebook, chinese = read_notebook(chinese_path)
        comparisons = {
            "cell count": len(english_notebook["cells"]) == len(chinese_notebook["cells"]),
            "anchors": anchors == ANCHOR_PATTERN.findall(chinese),
            "code": blocks == code_blocks(chinese),
            "image paths": images == image_paths(chinese),
            "heading levels": HEADING_PATTERN.findall(english)
            == HEADING_PATTERN.findall(chinese),
            "display-math block count": len(DISPLAY_MATH_PATTERN.findall(english))
            == len(DISPLAY_MATH_PATTERN.findall(chinese)),
            "table count": len(TABLE_SEPARATOR_PATTERN.findall(english))
            == len(TABLE_SEPARATOR_PATTERN.findall(chinese)),
            "details count": english.count("<details>") == chinese.count("<details>"),
        }
        failed = [name for name, passed in comparisons.items() if not passed]
        if failed:
            raise AssertionError(
                f"{chinese_path}: bilingual mismatch in {', '.join(failed)}"
            )

    return {
        "cells": len(english_notebook["cells"]),
        "anchors": len(anchors),
        "examples": len(blocks),
        "images": len(images),
        "bilingual": bilingual,
    }


def local_html_target(page: Path, reference: str) -> Path | None:
    parsed = urlsplit(reference.replace("\\", "/"))
    if parsed.scheme or parsed.netloc or reference.startswith(("#", "data:")):
        return None
    clean = unquote(parsed.path)
    if not clean or clean == "/":
        return None
    if clean.startswith("/ipynb/"):
        return SOURCE_ROOT / clean.lstrip("/")
    if clean.startswith("/"):
        return None
    return (page.parent / clean).resolve()


def validate_html(
    page: Path,
    anchors: list[str],
    expected_images: int,
    require_language_switch: bool,
    require_guideline_navigation: bool,
) -> None:
    if not page.is_file():
        raise AssertionError(f"rendered HTML missing: {page}")
    html = page.read_text(encoding="utf-8")

    for anchor in anchors:
        if not re.search(
            rf"\bid=[\"']{re.escape(anchor)}[\"']",
            html,
            re.IGNORECASE,
        ):
            raise AssertionError(f"{page}: rendered anchor missing: {anchor}")

    required_markers = [
        "blog-page-nav",
        "blog-images.css",
        "reading-toolbar.css",
        "reading-toolbar.js",
    ]
    if require_language_switch:
        required_markers.append("blog-language-switch")
    for marker in required_markers:
        if marker not in html:
            raise AssertionError(f"{page}: required marker missing: {marker}")

    navigation = re.search(
        r'<div class="blog-page-nav"[^>]*>(.*?)</div>',
        html,
        re.IGNORECASE | re.DOTALL,
    )
    if not navigation or 'href="/"' not in navigation.group(1):
        raise AssertionError(f"{page}: Home navigation is missing")
    navigation_links = re.findall(
        r"""href=["']([^"']+)["']""",
        navigation.group(1),
    )
    local_navigation_targets = [
        local_html_target(page, link)
        for link in navigation_links
        if link != "/"
    ]
    if require_guideline_navigation:
        if not local_navigation_targets or not all(
            target is not None and target.is_file()
            for target in local_navigation_targets
        ):
            raise AssertionError(f"{page}: guideline navigation target is missing")
    elif not all(
        target is not None and target.is_file()
        for target in local_navigation_targets
    ):
        raise AssertionError(f"{page}: local navigation target is missing")

    if require_language_switch:
        switch = re.search(
            r'<div class="blog-language-switch"[^>]*>(.*?)</div>',
            html,
            re.IGNORECASE | re.DOTALL,
        )
        if not switch:
            raise AssertionError(f"{page}: language switch is missing")
        language_links = re.findall(
            r"""href=["']([^"']+)["']""",
            switch.group(1),
        )
        if not language_links:
            raise AssertionError(f"{page}: language switch target is missing")
        language_target = local_html_target(page, language_links[0])
        if language_target is None or not language_target.is_file():
            raise AssertionError(
                f"{page}: language target does not resolve: {language_links[0]}"
            )

    local_images = [
        match.group("path")
        for match in HTML_IMAGE_PATTERN.finditer(html)
        if local_html_target(page, match.group("path")) is not None
    ]
    for reference in local_images:
        target = local_html_target(page, reference)
        if target is not None and not target.is_file():
            raise AssertionError(f"{page}: rendered image is missing: {reference}")

    lightboxes = len(
        re.findall(
            r"""<a\b[^>]*class=["'][^"']*\blightbox\b""",
            html,
            re.IGNORECASE,
        )
    )
    if expected_images and lightboxes < expected_images:
        raise AssertionError(
            f"{page}: expected at least {expected_images} Lightbox images, found {lightboxes}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compact source and HTML checks for one bilingual blog chapter."
    )
    parser.add_argument("--english", type=Path, required=True)
    parser.add_argument("--chinese", type=Path)
    parser.add_argument("--english-html", type=Path)
    parser.add_argument("--chinese-html", type=Path)
    parser.add_argument("--execute-code", action="store_true")
    parser.add_argument("--allow-monolingual", action="store_true")
    args = parser.parse_args()

    english = args.english.resolve()
    chinese = args.chinese.resolve() if args.chinese else None
    if not english.is_file():
        raise AssertionError(f"English notebook missing: {english}")
    if chinese is not None and not chinese.is_file():
        raise AssertionError(f"Chinese notebook missing: {chinese}")

    summary = validate_source(english, chinese, args.execute_code)
    english_notebook, english_body = read_notebook(english)
    anchors = ANCHOR_PATTERN.findall(english_body)
    english_yaml = source_text(english_notebook["cells"][0])
    is_guideline = bool(
        re.search(r"^title:\s*[^\n]*\bGuideline\b", english_yaml, re.MULTILINE)
    )

    if args.english_html:
        validate_html(
            args.english_html.resolve(),
            anchors,
            int(summary["images"]),
            not args.allow_monolingual,
            not is_guideline,
        )
    if args.chinese_html:
        validate_html(
            args.chinese_html.resolve(),
            anchors,
            int(summary["images"]),
            True,
            not is_guideline,
        )

    code_state = "executed" if args.execute_code else "not-executed"
    print(
        "validation passed: "
        f"cells={summary['cells']}; anchors={summary['anchors']}; "
        f"examples={summary['examples']} ({code_state}); images={summary['images']}; "
        f"bilingual={'yes' if summary['bilingual'] else 'no'}; "
        f"html={'yes' if args.english_html else 'no'}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
