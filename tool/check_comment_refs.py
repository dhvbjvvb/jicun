#!/usr/bin/env python3
"""Checks that identifiers named in comments with backticks still exist in real code.

Why this exists: the cheapest kind of rot is a comment that names a function which was
renamed or deleted. Nothing turns red -- no test, no analyzer -- and the next reader is
sent looking for something that is not there. This script does that one job: take every
word in backticks inside *comments* of Dart / Kotlin / Python sources and look it up in
*code*. Comment lines are stripped before the lookup, so a name that only survives in
some other comment still counts as missing.

The judgement is deliberately conservative, because a checker that cries wolf gets
ignored. A backticked word is only checked when it actually *looks like one of our
names*: `_private`, `camelCase` or `SCREAMING_CASE`. Prose, paths, file names, shell
flags, lowercase data (`moof`, `main_url`), `_1` style placeholders and `Type.method`
with a lowercase member are all skipped on sight. Foreign names that comments mention on
purpose -- server-side tables, Android constants, SDK methods we deliberately do not
call -- live in FOREIGN below, each group saying why it is there.

PowerShell (.ps1) is not scanned: there, backticks are the escape character, so
"backticked word" is not a comment-reference convention.

Usage (from the repo root):

    python tool/check_comment_refs.py               # non-zero exit if something drifted
    python tool/check_comment_refs.py --list-skips  # also list what was skipped, and why

Outputs: one line per drifted reference -- file, line and the token.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Where the tokens live (comments are read here) and where they must exist (code is read
# here). One set: a name mentioned in lib/ may legitimately be defined in test/.
SOURCE_DIRS = [
    ROOT / "lib",
    ROOT / "test",
    ROOT / "integration_test",
    ROOT / "tool",
    ROOT / "android" / "app" / "src",
]
SUFFIXES = {".dart", ".kt", ".py"}

TOKEN_RE = re.compile(r"`([^`\n]+)`")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
FILE_LIKE_RE = re.compile(
    r"\.(dart|kt|py|json|ps1|sh|bat|md|ya?ml|png|jpe?g|webp|apk|jar|txt|xml|gradle|kts|toml|lock)$",
    re.IGNORECASE,
)
# The shapes our own identifiers come in. Anything else is somebody else's business.
PRIVATE_RE = re.compile(r"^_[A-Za-z]\w*$")
CAMEL_RE = re.compile(r"^[a-z][a-z0-9]*[A-Z]\w*$")
UPPER_CAMEL_RE = re.compile(r"^[A-Z][a-z0-9]+[A-Z]\w*$")
SCREAMING_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$")
MIN_NAME = 3  # `_n` / `_1` are placeholders in prose, not names

# Real names that comments point at on purpose. Each group says why it is here -- and
# every entry is a name nobody checks any more, so the list is meant to stay short.
FOREIGN = {
    "服务端(Go/Python)的表名/字段名": {"DOMAIN_TO_NAME", "_fetch_audio_stream"},
    "Android framework": {
        "UI_MODE_NIGHT_UNDEFINED",
        "MODE_NIGHT_CUSTOM",
        "LaunchTheme",
        "getNightMode",
    },
    "Dart SDK / Flutter": {
        "showCupertinoDialog",
        "_ConnectionTarget",
        "MultiFrameImageStreamCompleter",
        "idleTimeout",
    },
    "SVG 关键字(配 flutter_svg 的 SvgTheme)": {"SvgTheme", "currentColor"},
    "JDK(点名是为了说明为什么不用它)": {"transferTo"},
    "第三方包内部(liquid_glass_widgets)": {"BottomBarTabItem"},
    "浏览器侧网络错误码": {"ERR_CONNECTION_RESET"},
}
CATEGORY = {name: group for group, names in FOREIGN.items() for name in names}


def split_comment(line: str, suffix: str) -> tuple[str, str]:
    """Splits one line into (code, comment). Comment-only lines return empty code."""
    markers = ("#",) if suffix == ".py" else ("//",)
    stripped = line.lstrip()
    if stripped.startswith(markers):
        return "", stripped
    if suffix != ".py" and stripped.startswith(("*", "/*")):
        return "", stripped
    index = 0
    while True:
        found = [line.find(marker, index) for marker in markers]
        found = [position for position in found if position >= 0]
        if not found:
            return line, ""
        position = min(found)
        # `//` right after a `:` is a URL (`https://`), not a comment.
        if line[position] == "/" and position > 0 and line[position - 1] == ":":
            index = position + 2
            continue
        return line[:position], line[position:]


def each_source():
    for directory in SOURCE_DIRS:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*")):
            if path.suffix in SUFFIXES and path.is_file():
                yield path


def looks_like_name(part: str) -> bool:
    if len(part) < MIN_NAME:
        return False
    return bool(
        PRIVATE_RE.match(part)
        or CAMEL_RE.match(part)
        or UPPER_CAMEL_RE.match(part)
        or SCREAMING_RE.match(part)
    )


def segments(token: str) -> list[str] | None:
    """The identifiers a backticked token names, or None if it is not code-shaped."""
    cleaned = token.strip()
    if cleaned.endswith("()"):
        cleaned = cleaned[:-2]
    if not cleaned or " " in cleaned or FILE_LIKE_RE.search(cleaned):
        return None
    parts = cleaned.split(".")
    if not all(IDENT_RE.match(part) for part in parts):
        return None
    if not all(looks_like_name(part) for part in parts):
        return None
    return parts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--list-skips", action="store_true", help="also print tokens that were skipped"
    )
    args = parser.parse_args()

    code_parts: list[str] = []
    comments: list[tuple[Path, int, str]] = []
    for path in each_source():
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            code, comment = split_comment(line, path.suffix)
            if code:
                code_parts.append(code)
            for token in TOKEN_RE.findall(comment):
                comments.append((path, number, token))
    code_text = "\n".join(code_parts)

    drifted = 0
    skips: list[str] = []
    for path, number, token in comments:
        where = f"{path.relative_to(ROOT)}:{number}"
        parts = segments(token)
        if parts is None:
            if args.list_skips:
                skips.append(f"{where}  `{token}`  -- 不是代码名的形状")
            continue
        foreign = next((part for part in parts if part in CATEGORY), None)
        if foreign is not None:
            if args.list_skips:
                skips.append(f"{where}  `{token}`  -- 外部名({CATEGORY[foreign]})")
            continue
        missing = [
            part
            for part in parts
            if not re.search(rf"\b{re.escape(part)}\b", code_text)
        ]
        if missing:
            drifted += 1
            print(f"{where}  `{token}`  -- 代码里找不到:{', '.join(missing)}")
    if args.list_skips:
        print(f"\n-- 跳过 {len(skips)} 处 --")
        for line in skips:
            print(line)
    if drifted:
        print(
            f"\n{drifted} 处注释点到的东西在代码里找不到(改名/删了没同步?)。"
            "确实是外部名字就加进 FOREIGN,别把它从注释里删掉。"
        )
        return 1
    print("注释里的反引号引用都在代码里找得到。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
