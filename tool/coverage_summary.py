#!/usr/bin/env python3
"""Print a coverage summary from an lcov file. For reading, not for gating.

Why this exists, and why it is not a gate: the number proves nothing in either
direction. Widget rendering code is naturally hard to cover; a file's percentage goes up
just as well by adding three shallow cases as by walking the one branch that matters.
What the number *is* good for is answering "which branches has nobody walked" -- that is
a question for a human to read, not for CI to decide. So the job that runs this is
continue-on-error: a red coverage step never blocks a merge.

Usage (repo root, after `flutter test --coverage`):

    python3 tool/coverage_summary.py                  # reads coverage/lcov.info
    python3 tool/coverage_summary.py path/to/lcov.info
    python3 tool/coverage_summary.py --self-check      # checks the parser itself

Output is markdown: CI appends it to $GITHUB_STEP_SUMMARY, and it reads fine in a
terminal too.
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_LCOV = "coverage/lcov.info"
TOP_MISSED = 10

# lcov 的计数器前缀 -> 收到记录里的哪个字段。没出现的按 0 算(有些文件就是不带分支)。
COUNTERS = {
    "LF:": "lines_found",
    "LH:": "lines_hit",
    "FNF:": "fns_found",
    "FNH:": "fns_hit",
    "BRF:": "branch_found",
    "BRH:": "branch_hit",
}


@dataclass
class Cover:
    """一个 SF 块的数字。名字带 found 的是总数,带 hit 的是走过的。"""

    file: str
    lines_found: int = 0
    lines_hit: int = 0
    fns_found: int = 0
    fns_hit: int = 0
    branch_found: int = 0
    branch_hit: int = 0


def _count(text: str) -> int:
    """坏行按 0 算:摘要是给人看的,不该因为一行读不懂就整个报错(空行也算 0)。"""
    try:
        return int(text.strip())
    except ValueError:
        return 0


def parse(text: str) -> list[Cover]:
    """One record per SF:..end_of_record block."""
    records: list[Cover] = []
    current: Cover | None = None
    for line in text.splitlines():
        if line.startswith("SF:"):
            current = Cover(file=line[3:].strip())
            continue
        if current is None:
            continue
        if line.startswith("end_of_record"):
            records.append(current)
            current = None
            continue
        for prefix, field_name in COUNTERS.items():
            if line.startswith(prefix):
                setattr(current, field_name, _count(line[len(prefix) :]))
                break
    if current is not None:
        records.append(current)
    return records


def pct(hit: int, found: int) -> str:
    """N/A rather than a ZeroDivisionError: lcov leaves counters out for some files."""
    return f"{100 * hit / found:.1f}%" if found else "—"


def _cell(hit: int, found: int) -> str:
    return f"{hit} / {found} ({pct(hit, found)})"


def render(records: list[Cover]) -> str:
    if not records:
        return "lcov 里一条记录都没有,这次没有摘要。\n"
    lib = [record for record in records if record.file.startswith("lib/")]
    scope, label = (lib, "lib/") if lib else (records, "全部")
    lines = (sum(r.lines_hit for r in scope), sum(r.lines_found for r in scope))
    fns = (sum(r.fns_hit for r in scope), sum(r.fns_found for r in scope))
    branch = (sum(r.branch_hit for r in scope), sum(r.branch_found for r in scope))
    cells = [
        f"{label}({len(scope)} 个文件)",
        _cell(*lines),
        _cell(*fns),
        _cell(*branch),
    ]
    out = [
        "## 覆盖率(参考用,不作门)\n",
        "| 范围 | 行 | 函数 | 分支 |",
        "| --- | --- | --- | --- |",
        "| " + " | ".join(cells) + " |",
        "",
        f"没走过的行最多的 {TOP_MISSED} 个文件(安静地出错的地方通常就在这几个里):\n",
        "| 文件 | 没走过的行 | 行覆盖 |",
        "| --- | --- | --- |",
    ]
    ranked = sorted(scope, key=lambda r: r.lines_found - r.lines_hit, reverse=True)
    for record in ranked[:TOP_MISSED]:
        missed = record.lines_found - record.lines_hit
        out.append(f"| {record.file} | {missed} | {pct(record.lines_hit, record.lines_found)} |")
    return "\n".join(out) + "\n"


def self_check() -> int:
    """Feeds the parser a hand-written lcov and checks the arithmetic that matters."""
    sample = "\n".join(
        [
            "TN:",
            "SF:lib/a.dart",
            "LF:10",
            "LH:4",
            "FNF:2",
            "FNH:1",
            "BRF:4",
            "BRH:0",
            "end_of_record",
            "SF:lib/b.dart",
            "LF:6",
            "LH:6",
            "end_of_record",
        ]
    )
    records = parse(sample)
    summary = render(records)
    ok_first = records[0] if records else Cover(file="?")
    ok_last = records[1] if len(records) > 1 else Cover(file="?")
    cases = [
        (len(records) == 2, "读到两条 SF 记录"),
        (ok_first.file == "lib/a.dart", "文件名"),
        (sum(r.lines_found for r in records) == 16, "行数合计"),
        (sum(r.lines_hit for r in records) == 10, "命中行合计"),
        (ok_last.branch_found == 0, "没写的计数器读成 0"),
        (pct(10, 16) == "62.5%", "百分比保留一位小数"),
        (pct(0, 0) == "—", "没有可数的行时不除零"),
        ("lib/a.dart" in summary, "摘要里带文件名"),
        ("end_of_record" not in summary, "摘要里不出现 lcov 原文"),
    ]
    failed = [name for passed, name in cases if not passed]
    for name in failed:
        print(f"  FAIL  {name}")
    print(f"自查通过 {len(cases) - len(failed)}/{len(cases)}")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lcov", nargs="?", default=DEFAULT_LCOV, help="lcov.info 的路径")
    parser.add_argument("--self-check", action="store_true", help="只自查解析,不读文件")
    args = parser.parse_args()
    if args.self_check:
        return self_check()
    path = Path(args.lcov)
    if not path.is_file():
        print(f"没有 {path} —— 先跑 flutter test --coverage 再来看摘要。")
        return 0
    print(render(parse(path.read_text(encoding="utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
