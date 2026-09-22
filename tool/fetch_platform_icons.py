#!/usr/bin/env python3
"""拉各平台在 App Store 上的最新图标,做成 assets/platform-icons/*.png。

「使用帮助及反馈」二级页每张平台卡左边要一个官方图标,手抠 18 张太累,这里按
App Store 的 trackId 直接取:``artworkUrl512`` 给的是 512x512 的成品图,是平台
自己在 App Store 上挂的那一张,改版了重跑本脚本就能跟上。

    python tool/fetch_platform_icons.py            # 缺哪张拉哪张
    python tool/fetch_platform_icons.py --force    # 全部重拉
    python tool/fetch_platform_icons.py --sheet    # 顺手拼一张验收对照图

落盘的尺寸是 192x192:卡片里按 40dp 画,xxhdpi 上要 120 物理像素,192 留了余量,
再大就是白占 APK 体积。JPG 源转 PNG 是因为图标要圆角裁切,PNG 带 alpha 更省心。

只依赖标准库 + Pillow(和 tool/make_header_art.py 一样)。
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "platform-icons"

# 卡片里显示的名字 → App Store trackId。名字是**本 APP 里**的叫法,和商店标题
# 不必一致(商店标题会随时挂活动后缀,比如「央视频-看亚运会」)。
# trackId 用 itunes lookup 查得:https://itunes.apple.com/lookup?id=<id>&country=cn
PLATFORMS: list[tuple[str, str, int]] = [
    ("今日头条", "toutiao", 529092160),
    ("快手", "kuaishou", 440948110),
    ("抖音", "douyin", 1142110895),
    ("微信公众号", "wechat", 414478124),
    ("微信视频号", "wechat_channels", 414478124),
    ("小红书", "xiaohongshu", 741292507),
    ("汽水音乐", "qishui", 1605585211),
    ("豆包", "doubao", 6459478672),
    ("哔哩哔哩", "bilibili", 736536022),
    ("微博", "weibo", 350962117),
    ("央视频", "yangshipin", 1479814602),
    ("皮皮搞笑", "pipigaoxiao", 1423061888),
    ("皮皮虾", "pipixia", 1393912676),
    ("最右", "zuiyou", 942443472),
    ("红果短剧", "hongguoduanju", 6451407032),
    ("红果漫剧", "hongguomanju", 6745890963),
    ("好看视频", "haokan", 1092031003),
    ("西瓜视频", "xigua", 1134496215),
]

SIZE = 192
UA = "untitled-app-icon-fetcher/1.0"


def artwork_url(track_id: int) -> str:
    """查这张图标在商店里的原图地址,并把尺寸规格换成 [SIZE]。"""
    url = f"https://itunes.apple.com/lookup?id={track_id}&country=cn"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    if not data.get("results"):
        raise RuntimeError(f"trackId {track_id} 在国区商店查不到")
    art = data["results"][0]["artworkUrl512"]
    # 形如 .../512x512bb.jpg:换掉尺寸段就是同一张图的不同规格,bb 的那层底
    # (白底/黑底内边距)保持不变。
    head, _, tail = art.rpartition("/")
    name = tail.split("bb.")[-1]
    return f"{head}/{SIZE}x{SIZE}bb.{name}"


def download(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def fetch_one(name: str, slug: str, track_id: int, force: bool) -> str:
    out = OUT_DIR / f"{slug}.png"
    if out.exists() and not force:
        return f"跳过  {name:<8} {out.name} 已存在"
    url = artwork_url(track_id)
    raw = download(url)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    tmp.write_bytes(raw)
    try:
        img = Image.open(tmp).convert("RGB")
    finally:
        tmp.unlink(missing_ok=True)
    if img.size != (SIZE, SIZE):
        img = img.resize((SIZE, SIZE), Image.LANCZOS)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    return f"下载  {name:<8} {out.name}  {out.stat().st_size / 1024:.0f} KB"


def sheet() -> Path:
    """18 张拼一张对照图:一眼看完有没有拉错图标。"""
    cols, cell, pad = 6, SIZE, 12
    rows = (len(PLATFORMS) + cols - 1) // cols
    plate = Image.new(
        "RGB", (cols * cell + (cols + 1) * pad, rows * cell + (rows + 1) * pad), (245, 247, 250)
    )
    for i, (_, slug, _) in enumerate(PLATFORMS):
        img = Image.open(OUT_DIR / f"{slug}.png").convert("RGB")
        x = pad + (i % cols) * (cell + pad)
        y = pad + (i // cols) * (cell + pad)
        plate.paste(img, (x, y))
    out = OUT_DIR / "_sheet.png"
    plate.save(out)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="拉平台 App Store 图标")
    ap.add_argument("--force", action="store_true", help="已存在的也重拉")
    ap.add_argument("--sheet", action="store_true", help="额外拼一张对照图")
    args = ap.parse_args()

    failed = 0
    for name, slug, track_id in PLATFORMS:
        try:
            print(fetch_one(name, slug, track_id, args.force))
        except Exception as exc:  # 网络抽风不该让整批白跑
            failed += 1
            print(f"失败  {name:<8} {exc}", file=sys.stderr)
    if args.sheet:
        print(f"对照图 {sheet()}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
