#!/usr/bin/env python3
"""把抠好底的插画做成二级页顶栏资源(assets/theme-header/*.png)。

最省事的用法是双击 ``tool\\一键顶栏图.bat``,把图片拖进去回车。命令行等价于::

    python tool/make_header_art.py 抠图.png                        # 自动挑下一个空名字
    python tool/make_header_art.py 抠图.png -o 目标.png --preview   # 指定输出
    python tool/make_header_art.py 抠图.png --patch                # 顺手改代码引用(默认通知管理这页)
    python tool/make_header_art.py 抠图.png --patch 主题与外观      # 改别的页
    python tool/make_header_art.py 抠图.png --align left           # 靠左/靠右摆(默认居中)
    python tool/make_header_art.py 抠图.png --top 40               # 整体往上挪(默认垂直居中)
    python tool/make_header_art.py                                # 不带图:交互式让你拖一张进来
    python tool/make_header_art.py --selftest                      # 几何自检,不写项目文件

中文提示全部由本脚本打印,一键顶栏图.bat 里只有 ASCII——cmd 只要碰到 `chcp 65001`
就会按错的字节偏移重读批处理文件,中文行会被切碎,所以那边一个字都不放。

依赖 Pillow(``python -m pip install pillow``)。

规则抄自现有的 assets/theme-header/theme_top.png:内容紧贴槽位铺满,四周只留
MARGIN 的透明边。内容比槽位宽就按宽度撑满、上下居中等分留白;比槽位窄就按高度
撑满、左右居中——两条分支都走 ``min(...)`` 的等比缩放,不会拉伸变形。

描边是一圈白色垫在原图**下面**:深色模式下靠它把角色从深色背景里拎出来(黑帽子、
黑裙这类暗色主体尤其需要),浅色模式下白描边和背景同色等于隐形。所以深浅两模式
共用同一张图,不需要出两版。

画布比例从 lib/main.dart 的 ``_kHeaderArtAspect`` 读,读不到才用内置默认值——
比例是代码里写死的,让它当唯一事实来源,免得哪天改了比例忘了同步脚本。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageFilter, ImageOps

ROOT = Path(__file__).resolve().parent.parent
DART = ROOT / "lib" / "main.dart"
OUT_DIR = ROOT / "assets" / "theme-header"

# 抄自现有资源的值:1406x605 的画布、四周 6px 留白
DEFAULT_CANVAS = (1406, 605)
DEFAULT_MARGIN = 6
DEFAULT_OUTLINE = 4

# 判定「这里有内容」的 alpha 阈值。抠图工具的软边会留一圈半透明像素,
# 阈值太低会把它们当成内容,裁出来的 bbox 就比实际画面大一圈。
ALPHA_MIN = 8

# 一键顶栏图.bat 不带第二个参数时要挂的页面。
DEFAULT_PAGE = "通知管理"


def asset_rel(out: Path) -> str | None:
    """输出文件在项目里的相对路径;不在项目里返回 None(那种路径引不到)。"""
    try:
        return out.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return None


def dart_line(out: Path) -> str | None:
    """可以粘进 _SubPage 的那一行。"""
    rel = asset_rel(out)
    return f"headerImage: '{rel}'," if rel else None


def canvas_from_dart(width: int) -> tuple[int, int]:
    """从 lib/main.dart 读 ``_kHeaderArtAspect`` 算出画布尺寸;读不到就用默认值。"""
    try:
        src = DART.read_text(encoding="utf-8")
    except OSError:
        return DEFAULT_CANVAS
    m = re.search(r"_kHeaderArtAspect\s*=\s*([\d.]+)\s*/\s*([\d.]+)", src)
    if not m:
        return DEFAULT_CANVAS
    num, den = float(m.group(1)), float(m.group(2))
    if num <= 0 or den <= 0:
        return DEFAULT_CANVAS
    return width, max(1, round(width * den / num))


def content_bbox(img: Image.Image, threshold: int = ALPHA_MIN):
    """内容的外接矩形(基于 alpha),整张透明时返回 None。"""
    return img.getchannel("A").point(lambda v: 255 if v > threshold else 0).getbbox()


def outlined(art: Image.Image, radius: int) -> Image.Image:
    """给图垫一圈白色描边。radius 为 0 时原样返回。

    alpha 膨胀用的是方形核(横竖各一次极值),圆角和圆核的差别在这个半径下看不出来。
    膨胀后再轻微高斯一下,把硬边磨成抗锯齿的过渡,否则曲线边缘会有台阶。
    """
    if radius <= 0:
        return art
    grown = art.getchannel("A").filter(ImageFilter.MaxFilter(2 * radius + 1))
    grown = grown.filter(ImageFilter.GaussianBlur(1.0))
    halo = Image.new("RGBA", art.size, (255, 255, 255, 255))
    halo.putalpha(grown)
    return Image.alpha_composite(halo, art)


def next_asset_name(out_dir: Path = OUT_DIR) -> Path:
    """在 assets/theme-header/ 里挑一个没被占用的 theme_top_N.png。

    从 _2 开始编号(不带数字的 theme_top.png 是手写的那张原始资源,不占用):
    重复跑同一张源图不会覆盖上一张,代码引的永远是最后生成的那一个。
    """
    n = 2
    while (out_dir / f"theme_top_{n}.png").exists():
        n += 1
    return out_dir / f"theme_top_{n}.png"


def patch_page(page: str, out: Path) -> str:
    """把生成好的图写进 lib/main.dart 里该页 `_SubPage` 的 headerImage。

    只替换已有那一行的字符串,不新增/删除代码;找不到唯一目标就原样不动,
    把该粘的那行打出来让人自己加。
    """
    rel = asset_rel(out)
    if rel is None:
        return "输出不在项目里,没法写进代码"

    lines = DART.read_text(encoding="utf-8").splitlines(keepends=True)
    hits = [i for i, line in enumerate(lines) if f"title: '{page}'" in line]
    if len(hits) != 1:
        return f"没找到唯一的 title: '{page}'(命中 {len(hits)} 处),代码没动"

    start = hits[0]
    for i in range(start, min(start + 40, len(lines))):
        if i > start and "_SubPage(" in lines[i]:
            break
        m = re.match(r"(\s*)headerImage:\s*'[^']*',", lines[i])
        if m:
            lines[i] = f"{m.group(1)}headerImage: '{rel}',\n"
            DART.write_text("".join(lines), encoding="utf-8")
            return f"lib/main.dart:{i + 1}  {page} → {rel}"
    return f"{page} 这页还没有 headerImage,自己加一行:headerImage: '{rel}',"


def fit_contain(content: Image.Image, canvas, margin: int) -> tuple[Image.Image, tuple[int, int]]:
    """按源图自身比例等比缩放进画布(扣掉留白),返回图和落点。

    给 ``--outline 0`` 用:白描边一旦关掉,再把内容塞进画布比例就会把宽的插画压成
    一条(1406x605 的画布塞 16:9 的内容,高度只剩一半),所以这里不凑画布比例,
    直接照源图比例缩放到能塞进可用区、居中摆。上下(或左右)留的是透明边,
    观感和主资源一致,不会露出白边。
    """
    cw, ch = canvas
    avail = (max(1, cw - 2 * margin), max(1, ch - 2 * margin))
    art = ImageOps.contain(content, avail, Image.LANCZOS)
    return art, ((cw - art.width) // 2, (ch - art.height) // 2)


def build(src: Path, out: Path, canvas, margin: int, outline: int, align: str = "center",
          top: int | None = None) -> dict:
    """跑完整条流水线,返回这次处理的各项实测尺寸。"""
    img = Image.open(src).convert("RGBA")

    corners = [
        img.getpixel(p)[3]
        for p in ((0, 0), (img.width - 1, 0), (0, img.height - 1), (img.width - 1, img.height - 1))
    ]
    if min(corners) > ALPHA_MIN:
        print("警告:源图四角不是透明的,可能还没抠底", file=sys.stderr)

    bbox = content_bbox(img)
    if bbox is None:
        raise SystemExit("源图整张透明,没有内容可放")
    content = img.crop(bbox)

    cw, ch = canvas
    avail_w = cw - 2 * (margin + outline)
    avail_h = ch - 2 * (margin + outline)
    if avail_w <= 0 or avail_h <= 0:
        raise SystemExit(f"画布 {cw}x{ch} 扣掉留白和描边后没有位置了")

    if outline <= 0:
        art, pos = fit_contain(content, canvas, margin)
        size = art.size
        scale = size[0] / content.width
    else:
        # 等比缩放到能塞进可用区,短边方向自然留白——宽图上下留,高图左右留。
        scale = min(avail_w / content.width, avail_h / content.height)
        size = (max(1, round(content.width * scale)), max(1, round(content.height * scale)))
        art = outlined(content.resize(size, Image.LANCZOS), outline)
        edge = margin + outline
        if align == "left":
            x = edge
        elif align == "right":
            x = cw - size[0] - edge
        else:
            x = (cw - size[0]) // 2
        pos = (x, (ch - size[1]) // 2 if top is None else top)

    plate = Image.new("RGBA", canvas, (0, 0, 0, 0))
    plate.alpha_composite(art, pos)
    out.parent.mkdir(parents=True, exist_ok=True)
    plate.save(out, optimize=True)

    return {
        "src_size": img.size,
        "bbox": bbox,
        "content": content.size,
        "content_aspect": content.width / content.height,
        "scale": scale,
        "art": size,
        "pos": pos,
        "align": align,
        "canvas": canvas,
    }


def write_preview(plate_path: Path, canvas) -> Path:
    """深浅两色背景拼一张对照图,用来肉眼验收描边效果。"""
    cw, ch = canvas
    art = Image.open(plate_path).convert("RGBA")
    sheet = Image.new("RGBA", (cw, ch * 2 + 20), (0, 0, 0, 0))
    for i, color in enumerate([(245, 247, 250, 255), (14, 17, 22, 255)]):
        bg = Image.new("RGBA", (cw, ch), color)
        bg.alpha_composite(art)
        sheet.paste(bg, (0, i * (ch + 20)))
    out = plate_path.with_name(plate_path.stem + "_preview.png")
    sheet.convert("RGB").save(out)
    return out


def report(src: Path, out: Path, info: dict, outline: int, margin: int) -> None:
    bbox = info["bbox"]
    print(f"源图      {src}")
    print(f"          画布 {info['src_size'][0]}x{info['src_size'][1]}  内容 bbox={bbox}  {info['content'][0]}x{info['content'][1]}  宽高比 {info['content_aspect']:.3f}")
    print(f"处理      等比缩放到 {info['art'][0]}x{info['art'][1]}(scale {info['scale']:.4f})"
          f"  白色描边 {outline}px  外圈留白 {margin}px  对齐 {info['align']}")
    print(f"落点      画布 {info['canvas'][0]}x{info['canvas'][1]}  内容起点 {info['pos']}")
    print(f"输出      {out}  {out.stat().st_size / 1024:.0f} KB")
    line = dart_line(out)
    if line:
        print(f"代码里引  {line}")
    else:
        print("提示      输出不在项目里;放进 assets/theme-header/ 后才能写进代码引用")


def selftest() -> int:
    """两条分支各验一次:宽内容上下留白、高内容左右留白。

    合成图特意垫一圈透明边(不是整张填满),这样顺带验了四角透明时不报警告。
    """
    canvas = (1406, 605)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        cases = [("宽", (1600, 400), "w"), ("高", (400, 1600), "h")]
        for name, content_size, kind in cases:
            src = tmp / f"{kind}.png"
            img = Image.new("RGBA", (content_size[0] + 40, content_size[1] + 40), (0, 0, 0, 0))
            img.paste(Image.new("RGBA", content_size, (200, 30, 30, 255)), (20, 20))
            img.save(src)
            out = tmp / f"{kind}_out.png"
            info = build(src, out, canvas, DEFAULT_MARGIN, DEFAULT_OUTLINE)

            got = content_bbox(Image.open(out).convert("RGBA"), 0)
            x0, y0, x1, y1 = got
            w, h = x1 - x0, y1 - y0
            avail_w = canvas[0] - 2 * (DEFAULT_MARGIN + DEFAULT_OUTLINE)
            avail_h = canvas[1] - 2 * (DEFAULT_MARGIN + DEFAULT_OUTLINE)

            assert w <= avail_w and h <= avail_h, (name, w, h)
            if kind == "w":  # 宽内容:宽度撑满,上下留白
                assert w == avail_w and h < avail_h, (name, w, h, avail_w, avail_h)
                assert y0 > 0 and x0 == DEFAULT_MARGIN + DEFAULT_OUTLINE, (x0, y0)
            else:  # 高内容:高度撑满,左右留白
                assert h == avail_h and w < avail_w, (name, w, h, avail_w, avail_h)
                assert x0 > 0 and y0 == DEFAULT_MARGIN + DEFAULT_OUTLINE, (x0, y0)
            print(f"  {name}内容 {content_size} → 内容框 {w}x{h} @ ({x0},{y0})  通过")

        # 无描边这条分支:内容按源图比例缩,不被画布比例压扁。
        src = tmp / "nooutline.png"
        wide = (1600, 400)  # 4.0,比画布 2.324 宽,旧逻辑会被压成一条
        img = Image.new("RGBA", (wide[0] + 40, wide[1] + 40), (0, 0, 0, 0))
        img.paste(Image.new("RGBA", wide, (200, 30, 30, 255)), (20, 20))
        img.save(src)
        out = tmp / "nooutline_out.png"
        build(src, out, canvas, DEFAULT_MARGIN, 0)

        got = content_bbox(Image.open(out).convert("RGBA"), 0)
        x0, y0, x1, y1 = got
        w, h = x1 - x0, y1 - y0
        assert abs(w / h - wide[0] / wide[1]) < 0.02, (w, h)
        assert w == canvas[0] - 2 * DEFAULT_MARGIN and y0 > 0, (w, h, y0)
        print(f"  无描边内容 {wide} → 内容框 {w}x{h} @ ({x0},{y0})  比例未变,通过")

    print("selftest 通过")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="抠好的插画 → 二级页顶栏资源")
    ap.add_argument("source", nargs="?", help="已经抠成透明底的 PNG;省略(或给空串)则让你拖一张进来")
    ap.add_argument("-o", "--out", type=Path, help="输出路径,默认自动挑 assets/theme-header/theme_top_N.png")
    ap.add_argument("--width", type=int, default=DEFAULT_CANVAS[0], help="画布宽度,高度按 _kHeaderArtAspect 算")
    ap.add_argument("--margin", type=int, default=DEFAULT_MARGIN, help="内容外圈留白")
    ap.add_argument("--outline", type=int, default=DEFAULT_OUTLINE, help="白色描边半径,0 表示不要描边")
    ap.add_argument(
        "--top",
        type=int,
        default=None,
        help="内容距画布顶部的距离(画布单位);不写就是垂直居中。想整体往上挪就调小它",
    )
    ap.add_argument(
        "--align",
        choices=("left", "center", "right"),
        default="center",
        help="内容在画布里的水平落点,默认居中;靠边时紧贴留白线,用来做左右角上的角色",
    )
    ap.add_argument(
        "--patch",
        nargs="?",
        const=DEFAULT_PAGE,
        default=None,
        metavar="页面标题",
        help=f"顺手把图写进 lib/main.dart 里该标题的 _SubPage;不写标题就是「{DEFAULT_PAGE}」",
    )
    ap.add_argument("--preview", action="store_true", help="额外输出深浅两色对照图")
    ap.add_argument("--selftest", action="store_true", help="跑几何自检,不写项目文件")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    # 命令行给的是空串(比如 bat 里 %~1 没展开)就退回交互式,让用户把图拖进来。
    raw = (args.source or "").strip().strip('"')
    if not raw:
        raw = input("把抠好底的 PNG 拖进这个窗口, 然后回车: ").strip().strip('"')
    if not raw:
        raise SystemExit("没拿到图片")

    src = Path(raw).expanduser().resolve()
    if not src.is_file():
        raise SystemExit(f"找不到源图:{src}")

    out = args.out.expanduser() if args.out else next_asset_name()
    canvas = canvas_from_dart(args.width)

    info = build(src, out, canvas, args.margin, args.outline, args.align, args.top)
    report(src, out, info, args.outline, args.margin)
    if args.patch is not None:
        print(f"改代码    {patch_page(args.patch or DEFAULT_PAGE, out)}")
    if args.preview:
        print(f"预览      {write_preview(out, canvas)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
