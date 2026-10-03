import argparse
import io
import os
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent

# 导出档位。三个脚本共用这一套:有损 q=92、method=6(最慢也最小)。
QUALITY = 92
METHOD = 6

JOBS = [
    # (src: 已经存在的那个文件, dst: 转换后写的目标, mode: lossy | lossless | auto)
    # 现在这批都已经转完了,下面这份是**记录**:源 PNG 不在仓库里了(母本在
    # _art-src/),所以这里只在 --check 时按 dst 报大小;重新转要先把 PNG 放回原位。
    #
    # 已经删掉的素材不要留在表里:theme_top_4 和彩蛋提示那两张(left/right)连着
    # WebP 一起出库了,留着只会让这个脚本每次都报"源和目标都没有"。
    ("assets/theme-header/theme_top.png", "assets/theme-header/theme_top.webp", "lossy"),
    ("assets/theme-header/theme_top_2.png", "assets/theme-header/theme_top_2.webp", "lossy"),
    ("assets/theme-header/theme_top_5.png", "assets/theme-header/theme_top_5.webp", "lossy"),
]


def encode(im: Image.Image, mode: str) -> tuple[bytes, str]:
    """按 mode 编码一份,返回 (字节, 用到的档位名)。不落盘。"""
    has_alpha = im.mode in ("RGBA", "LA", "P")
    rgba = im.convert("RGBA")
    buf = io.BytesIO()
    if mode == "lossless" or (mode == "auto" and not has_alpha):
        rgba.save(buf, "WEBP", lossless=True, quality=100, method=METHOD)
        return buf.getvalue(), "lossless"
    rgba.save(buf, "WEBP", quality=QUALITY, method=METHOD)
    return buf.getvalue(), "q=%d" % QUALITY


def main() -> int:
    ap = argparse.ArgumentParser(description="素材批量转 WebP")
    ap.add_argument("--check", action="store_true", help="只报大小,不写文件")
    args = ap.parse_args()

    total_before = 0.0
    total_after = 0.0
    missing = 0
    converted = 0
    for src_rel, dst_rel, mode in JOBS:
        src = ROOT / src_rel
        dst = ROOT / dst_rel
        if not src.exists():
            # 转完就把 PNG 从仓库里摘掉了。--check 只看现状,不算失败。
            if dst.exists():
                size = dst.stat().st_size / 1024
                print("%-42s %s已转 %7.1f KB" % (os.path.basename(dst_rel), " " * 26, size))
                total_after += size
            else:
                missing += 1
                print("%-42s 源和目标都没有" % src_rel, file=sys.stderr)
            continue
        converted += 1
        before = src.stat().st_size / 1024
        data, used = encode(Image.open(src), mode)
        after = len(data) / 1024
        total_before += before
        total_after += after
        if not args.check:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
        print("%-42s %7.1f KB -> %7.1f KB  %5.1f%%  %s" % (
            os.path.basename(src_rel), before, after, after / before * 100, used))

    print("-" * 78)
    if converted == 0:
        # 两批都转完了、PNG 也从仓库里摘掉了 —— 这里就该是这个样子,不是错误。
        print("没有源 PNG 可转;仓库里现有的 WebP 合计 %.1f KB" % total_after)
    elif args.check:
        print("现状合计 %.1f KB" % total_after)
    else:
        print("total %.1f KB -> %.1f KB  (saved %.1f KB, %.1f%%)" % (
            total_before, total_after, total_before - total_after,
            (1 - total_after / total_before) * 100 if total_before else 0))
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
