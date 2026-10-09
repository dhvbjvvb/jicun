#!/usr/bin/env python3
"""生成 README 底部那张「下载量」曲线图(assets/README 之外的仓库资产)。

为什么自己做一张:GitHub 不公开**按时间的下载曲线** —— 接口只给每个安装包的
`download_count`(一个总数),没有任何历史点。而现成的图表服务(比如 star-history.com
那种)只画 star,不画下载量。所以这里按「**版本顺序**」把各版本的下载量累加起来画一条
曲线:x 轴是版本,不是日期 —— 后者只会在发布那天挤成一根竖线,不诚实也不好看。

口径写在图上,别让它读起来像「每日下载量」:
  * y 是**累计**下载量(当前发布页上各版本安装包的 download_count 之和);
  * 只统计**当前还挂在发布页上**的版本 —— 删掉的版本连计数一起没了;
  * 每条曲线都标了生成日期,图会过期,要新数就重跑这个脚本。

用法(要联网;带 GITHUB_TOKEN 更稳,不带也能跑公开仓库):

    python tool/gen_downloads_chart.py                 # 写到 docs/downloads.svg
    python tool/gen_downloads_chart.py --out x.svg --repo owner/name
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = "dhvbjvvb/jicun"
DEFAULT_OUT = ROOT / "docs" / "downloads.svg"

# 和 README / 界面同一支蓝。曲线用红——和参考的那张图一个观感。
ACCENT = "#e05252"
GRID = "#e8e8e8"
TEXT = "#444444"
WIDTH, HEIGHT = 800, 400
PAD_LEFT, PAD_RIGHT, PAD_TOP, PAD_BOTTOM = 78, 24, 46, 62


def fetch_releases(repo: str) -> list[dict]:
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    # 带 token 就把限额抬高些;公开仓库不带也能跑,只是容易被限流。
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "jicun-gen-downloads-chart",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError) as error:  # 网络不通就说清楚
        raise SystemExit(f"拉不到发布列表:{error}") from error


def version_key(tag: str) -> tuple:
    """按版本号排序(v3.0.10 要排在 v3.0.9 后面,不能按字符串比)。"""
    numbers = [int(part) for part in re.findall(r"\d+", tag)]
    return (numbers or [0], tag)


def series(releases: list[dict]) -> list[tuple[str, int, int]]:
    """→ [(版本标签, 这一版自己的下载量, 累计到这一版的下载量)]。草稿不算。"""
    rows: list[tuple[str, int]] = []
    for release in releases:
        if release.get("draft"):
            continue
        downloads = sum(int(asset.get("download_count") or 0) for asset in release.get("assets") or [])
        rows.append((str(release.get("tag_name") or "?"), downloads))
    rows.sort(key=lambda row: version_key(row[0]))

    points: list[tuple[str, int, int]] = []
    running = 0
    for tag, downloads in rows:
        running += downloads
        points.append((tag, downloads, running))
    return points


def nice_step(top: int) -> int:
    """y 轴刻度步长:让刻度落在整数好读的数上,大概 5 格。"""
    for step in (10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 2500, 5000, 10000, 20000, 50000):
        if top / step <= 6:
            return step
    return 100000


def build_svg(repo: str, points: list[tuple[str, int, int]], today: str) -> str:
    plot_w = WIDTH - PAD_LEFT - PAD_RIGHT
    plot_h = HEIGHT - PAD_TOP - PAD_BOTTOM
    total = points[-1][2] if points else 0
    step = nice_step(total)
    top = max(step, ((total + step - 1) // step) * step)

    def x_at(index: int) -> float:
        if len(points) == 1:
            return PAD_LEFT + plot_w / 2
        return PAD_LEFT + plot_w * index / (len(points) - 1)

    def y_at(value: int) -> float:
        return PAD_TOP + plot_h * (1 - value / top)

    parts: list[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}" role="img" '
        f'aria-label="{escape(repo)} 各版本累计下载量">'
    )
    parts.append(f'<rect width="{WIDTH}" height="{HEIGHT}" fill="#ffffff"/>')

    # 横向网格 + y 轴刻度
    ticks = 0
    while ticks * step <= top:
        value = ticks * step
        y = y_at(value)
        parts.append(
            f'<line x1="{PAD_LEFT}" y1="{y:.1f}" x2="{PAD_LEFT + plot_w}" y2="{y:.1f}" '
            f'stroke="{GRID}" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{PAD_LEFT - 12}" y="{y + 4:.1f}" font-family="Helvetica,Arial,sans-serif" '
            f'font-size="12" fill="{TEXT}" text-anchor="end">{value}</text>'
        )
        ticks += 1

    # 曲线 + 数据点
    if len(points) >= 2:
        path = " ".join(
            ("M" if index == 0 else "L") + f"{x_at(index):.1f},{y_at(value):.1f}"
            for index, (_, _, value) in enumerate(points)
        )
        parts.append(f'<path d="{path}" fill="none" stroke="{ACCENT}" stroke-width="2.5"/>')
    for index, (_, _, value) in enumerate(points):
        x, y = x_at(index), y_at(value)
        parts.append(f'<rect x="{x - 3:.1f}" y="{y - 3:.1f}" width="6" height="6" fill="{ACCENT}"/>')

    # x 轴版本标签(多了就隔一个标一个)
    every = 1 if len(points) <= 8 else 2
    for index, (tag, _, _) in enumerate(points):
        if index % every:
            continue
        parts.append(
            f'<text x="{x_at(index):.1f}" y="{HEIGHT - PAD_BOTTOM + 20}" '
            f'font-family="Helvetica,Arial,sans-serif" font-size="11" fill="{TEXT}" '
            f'text-anchor="middle" transform="rotate(-30 {x_at(index):.1f} {HEIGHT - PAD_BOTTOM + 20})">'
            f"{escape(tag)}</text>"
        )

    # 轴与标签
    parts.append(
        f'<line x1="{PAD_LEFT}" y1="{PAD_TOP + plot_h}" x2="{PAD_LEFT + plot_w}" y2="{PAD_TOP + plot_h}" '
        f'stroke="{TEXT}" stroke-width="1.2"/>'
    )
    parts.append(
        f'<text x="20" y="{PAD_TOP + plot_h / 2:.1f}" font-family="Helvetica,Arial,sans-serif" '
        f'font-size="13" fill="{TEXT}" text-anchor="middle" '
        f'transform="rotate(-90 20 {PAD_TOP + plot_h / 2:.1f})">累计下载量</text>'
    )
    parts.append(
        f'<text x="{PAD_LEFT + plot_w / 2:.1f}" y="{HEIGHT - 14}" font-family="Helvetica,Arial,sans-serif" '
        f'font-size="13" fill="{TEXT}" text-anchor="middle">版本</text>'
    )

    # 图例(和参考那张图一样,居中一个方框)
    label = escape(repo)
    box_w = 12 * len(label) * 0.62 + 34
    box_x = (WIDTH - box_w) / 2
    parts.append(
        f'<rect x="{box_x:.1f}" y="12" width="{box_w:.1f}" height="26" rx="4" fill="none" '
        f'stroke="{TEXT}" stroke-width="1"/>'
    )
    parts.append(f'<rect x="{box_x + 10:.1f}" y="21" width="8" height="8" fill="{ACCENT}"/>')
    parts.append(
        f'<text x="{box_x + 24:.1f}" y="30" font-family="Helvetica,Arial,sans-serif" font-size="12" '
        f'fill="{TEXT}">{label}</text>'
    )

    # 口径说明 + 生成日期
    parts.append(
        f'<text x="{WIDTH - PAD_RIGHT}" y="{HEIGHT - 14}" font-family="Helvetica,Arial,sans-serif" '
        f'font-size="10" fill="#888888" text-anchor="end">当前发布页各版本累计 · 生成于 {today}</text>'
    )
    parts.append("</svg>\n")
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--out", default=str(DEFAULT_OUT))
    args = parser.parse_args()

    releases = fetch_releases(args.repo)
    points = series(releases)
    if not points:
        raise SystemExit("发布页上一个非草稿版本都没有,不画空图")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build_svg(args.repo, points, date.today().isoformat()), encoding="utf-8")

    print(f"写了 {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}:")
    for tag, downloads, running in points:
        print(f"  {tag:<10} 本版 {downloads:>6}  累计 {running:>6}")
    print(f"  合计 {points[-1][2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
