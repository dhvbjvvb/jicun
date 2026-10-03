"""检查动图素材(GIF / 动图 WebP)的尺寸、帧间隔和 alpha 真实情况。

用途:彩蛋动图选型时要反复比对转码结果,光看体积不够 —— 透明通道是不是真的在、
透明像素里存了什么 RGB、帧间隔有没有被转码改掉,这三件事决定最终观感。

看图器大多把透明渲染成白底或黑底,所以"看起来不透明"经常是看图的锅。
`--preview` 会把指定帧合成到洋红/深灰两种底色上存成 PNG,这个才骗不了人。

`--match-still` 用来对齐静图和动图:静图若是从动图导出的,它会指出对应第几帧,
顺便暴露"静图被压到黑底"这类问题(四角纯黑就是信号)。

    python tool/probe_animated.py <动图> [--preview [帧号]] [--width 像素]
    python tool/probe_animated.py <动图> --match-still <静图>
    python tool/probe_animated.py a.gif b.webp
"""

import struct
import sys
from collections import Counter

from PIL import Image, ImageChops, ImageSequence, ImageStat


def riff_chunks(path: str) -> list:
    """列出 WebP 的 RIFF 块。动图必须同时有 VP8X(带 ANIM 标志)和 ANIM 块,
    否则就是一张静图 —— 很多"转出来不动"或"转出来不透明"的问题在这里一眼可见。"""
    with open(path, "rb") as fh:
        head = fh.read(12)
        if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WEBP":
            print("不是 WebP(RIFF/WEBP 头不对)")
            return []
        chunks = []
        while True:
            header = fh.read(8)
            if len(header) < 8:
                break
            fourcc, size = struct.unpack("<4sI", header)
            chunks.append((fourcc.decode("latin-1"), size))
            fh.seek(size + (size & 1), 1)
    kinds = Counter(name for name, _ in chunks)
    print(f"RIFF chunks={dict(kinds)}")
    names = set(kinds)
    for need, why in (("VP8X", "扩展头"), ("ANIM", "动画头"), ("ANMF", "动画帧")):
        if need not in names:
            print(f">>> 缺 {need}({why})")
    return chunks


def _over(rgba: Image.Image, bg) -> Image.Image:
    canvas = Image.new("RGBA", rgba.size, bg)
    canvas.alpha_composite(rgba)
    return canvas.convert("RGB")


def _frame_at(im: Image.Image, index: int) -> Image.Image:
    """取第 index 帧的独立副本。

    不能用 `list(ImageSequence.Iterator(im))` —— 那个迭代器反复 seek 同一个
    Image 对象并原样 yield,列表里每一项都是同一个引用,取 [0] 和 [-1] 会拿到
    同一帧,算出来的"首末帧差"恒为 0。必须显式 seek 后立刻转成新图。"""
    im.seek(index)
    return im.convert("RGBA")


def preview(path: str, index: int, width: int | None) -> None:
    """把某一帧合成到洋红和深灰上,写成 PNG。透明没透明一眼可见。
    给了 --width 就按目标显示宽度缩一遍 —— 缩小会不会出暗边,这一步能直接看出来。"""
    im = Image.open(path)
    n = getattr(im, "n_frames", 1)
    rgba = _frame_at(im, index % n)
    tag = f"{path}.frame{index % n}"
    if width and width != rgba.width:
        rgba = rgba.resize((width, round(rgba.height * width / rgba.width)), Image.LANCZOS)
        tag += f".w{width}"
    for name, bg in (("magenta", (255, 0, 255, 255)), ("dark", (32, 34, 38, 255))):
        out = f"{tag}.{name}.png"
        _over(rgba, bg).save(out)
        print(f"preview -> {out}")


def match_still(anim_path: str, still_path: str) -> None:
    """静图和动图逐帧比,找出最接近的一帧。

    静图多半是从动图导出的,比对方式:动图每帧合成到黑底,再和静图求平均通道差。
    差值接近 0 说明静图就是那一帧(且被压过黑底)。"""
    still = Image.open(still_path).convert("RGB")
    black = (0, 0, 0, 255)
    im = Image.open(anim_path)
    best = (0, 1e9)
    first = None
    for i in range(getattr(im, "n_frames", 1)):
        rgba = _frame_at(im, i)
        if rgba.size != still.size:
            rgba = rgba.resize(still.size, Image.LANCZOS)
        mean = sum(ImageStat.Stat(ImageChops.difference(_over(rgba, black), still)).mean) / 3
        if i == 0:
            first = mean
        if mean < best[1]:
            best = (i, mean)
    corners = [still.getpixel(p) for p in ((0, 0), (still.width - 1, still.height - 1))]
    print(f"\n=== 静图对齐: {still_path}")
    print(f"静图 size={still.size} 四角={corners}")
    print(f"最接近第 {best[0]} 帧,平均通道差={best[1]:.2f}   第 0 帧差={first:.2f}")
    if best[1] < 2:
        print(f">>> 静图就是第 {best[0]} 帧压黑底导出的")
    elif best[1] > 10:
        print(">>> 差值偏大:静图不是这个动图的某一帧")
    if all(c == (0, 0, 0) for c in corners):
        print(">>> 四角纯黑:静图没有 alpha,背景是黑的")


def probe(path: str) -> None:
    im = Image.open(path)
    print(f"\n=== {path}")
    print(f"format={im.format} size={im.width}x{im.height} mode={im.mode}")
    print(f"frames={getattr(im, 'n_frames', 1)} animated={getattr(im, 'is_animated', False)} loop={im.info.get('loop')}")
    print(f"info={ {k: v for k, v in im.info.items() if k != 'icc_profile'} }")
    if im.format == "WEBP":
        riff_chunks(path)

    durations: list = []
    opaque = semi_pixels = pixels = 0
    clear = semi_frames = 0
    matte = Counter()
    for frame in ImageSequence.Iterator(im):
        rgba = frame.convert("RGBA")
        durations.append(frame.info.get("duration"))
        pixels += rgba.width * rgba.height
        for count, color in rgba.getcolors(maxcolors=1 << 24) or []:
            *_, alpha = color
            if alpha == 0:
                matte[tuple(color[:3])] += count
            elif alpha == 255:
                opaque += count
            else:
                semi_pixels += count
        hist = rgba.getchannel("A").histogram()
        if hist[0]:
            clear += 1
        if sum(hist[1:255]):
            semi_frames += 1
    print(f"durations(ms)={durations}")
    print(f"total={sum(d for d in durations if d)}ms  frames={len(durations)}")
    print(f"像素统计: 全不透明={opaque} 半透明={semi_pixels} 全透明={pixels - opaque - semi_pixels} / 共 {pixels}")
    print(f"含全透明像素的帧={clear} 含半透明像素的帧={semi_frames}")
    if matte:
        print(f"全透明像素里存的 RGB(top5)={matte.most_common(5)}")
        if semi_pixels == 0:
            print(">>> alpha 是二值的(0 或 255):边缘是硬边,不是羽化边")
    else:
        print(">>> 没有 alpha 通道 / alpha 恒为 255:背景透明已丢失")
    if len(durations) > 1:
        # 「播完一轮回静图」是否顺滑,取决于首末帧像不像。alpha 也算进差值。
        seam = (
            sum(
                ImageStat.Stat(
                    ImageChops.difference(
                        _frame_at(Image.open(path), 0),
                        _frame_at(Image.open(path), len(durations) - 1),
                    )
                ).mean
            )
            / 4
        )
        verdict = "接得上" if seam < 4 else "接不上,回静图会跳"
        print(f"首帧 vs 末帧 平均差={seam:.2f}  ({verdict})")


if __name__ == "__main__":
    argv = sys.argv[1:]
    if not argv:
        print(__doc__)
        raise SystemExit(2)

    def take_value(flag: str):
        """取出 --flag 后面的值,顺便把这一对从 argv 里摘掉。"""
        i = argv.index(flag)
        value = argv.pop(i + 1) if i + 1 < len(argv) else None
        argv.pop(i)
        return value

    frame = 20
    width = None
    still = None
    if "--match-still" in argv:
        still = take_value("--match-still")
    if "--width" in argv:
        width = int(take_value("--width") or 0) or None
    if "--preview" in argv:
        i = argv.index("--preview")
        value = argv[i + 1] if i + 1 < len(argv) else None
        if value is not None and value.isdigit():
            frame = int(argv.pop(i + 1))
        argv.pop(i)
    else:
        frame = None

    for arg in argv:
        probe(arg)
        if still:
            match_still(arg, still)
        if frame is not None:
            preview(arg, frame, width)
