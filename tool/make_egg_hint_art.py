"""Re-export the two characters used by the 彩蛋提示 page (assets/easter-egg-hint/).

Run by hand whenever the source artwork changes; not part of the build. The source
PNGs are 2016x1840 / 2160x2152 and arrive padded with a large transparent margin,
which the page cannot see: laid out in half-screen columns, a padded asset renders
its character much smaller than its box, and two assets with different padding
render at different sizes (the original 右边 character came out half the height of
左边). So each sheet is cropped to its own content plus a small margin, then
resized to a common 720 width.

Usage: python tool/make_egg_hint_art.py <左边.png> <右边.png>
"""

import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "easter-egg-hint"

# Width of the exported art. The page scales it down from here, so this only has to
# be comfortably above the widest phone's on-screen size.
WIDTH = 720
# Margin kept around the character, as a fraction of its own bounding box. Without
# it the crop clips the soft edge of the render.
MARGIN = 0.055


def export(src: Path, dst: Path) -> None:
    im = Image.open(src).convert("RGBA")
    box = im.getchannel("A").getbbox()
    if box is None:
        raise SystemExit(f"{src}: 整张图都是透明的")
    left, top, right, bottom = box
    pad = round(max(right - left, bottom - top) * MARGIN)
    crop = im.crop(
        (
            max(left - pad, 0),
            max(top - pad, 0),
            min(right + pad, im.width),
            min(bottom + pad, im.height),
        )
    )
    height = round(crop.height * WIDTH / crop.width)
    crop = crop.resize((WIDTH, height), Image.LANCZOS)
    dst.parent.mkdir(parents=True, exist_ok=True)
    crop.save(dst, optimize=True)
    print(f"{dst.name}: {crop.size} {dst.stat().st_size}B")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    export(Path(sys.argv[1]), OUT / "left.png")
    export(Path(sys.argv[2]), OUT / "right.png")


if __name__ == "__main__":
    main()
