"""Regenerate the 即存 launcher/notification icon assets from the source artwork.

Run by hand whenever the source PNG changes; not part of the build. The artwork
is a white bird on an opaque white sheet, so the sheet is flood-filled away and
the subject is re-composited at every density Android expects.

The bird is white, i.e. invisible against the white icon plate. The subject
therefore gets a hairline stroke in the colour of its own outline before it is
placed; without it the icon reads as a blank white square.

Outputs, per density:
  res/mipmap-*/ic_launcher.png             传统启动图标
  res/mipmap-*/ic_launcher_foreground.png  自适应图标前景层
  res/drawable-*/ic_notification.png       通知小图标(状态栏剪影)
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "图标.png"
RES = ROOT / "android" / "app" / "src" / "main" / "res"

# Plate behind the subject: the source art is drawn on white, so the icon keeps it.
PLATE = (255, 255, 255)
# How much of the source's own framing to keep. The artwork places the bird low in
# a square canvas with headroom above it; cropping tight to the subject throws that
# framing away and blows the bird up to the size of the icon. 1.0 reproduces the
# source framing exactly, 0.0 is a tight crop. The bird is only ~31% of the source
# canvas, so a high framing value shrinks it fast: keep this low, size with FILL_*.
FRAMING = 0.35
# The bird's own bounding box is not its visual centre: the tail and legs hang low,
# so centring the crop on the box leaves the subject sitting under the middle of
# the plate. Nudge the crop down to lift it, as a fraction of the crop side.
CENTER_OFFSET = 0.04
# Subject footprint inside the plate, as a fraction of the plate. Generous, because
# the framing above already keeps the bird off the edges.
FILL_LEGACY = 1.25
# The 108dp foreground canvas. Some launchers crop it straight to the squircle
# instead of showing the inner 66dp, so the bird has to stay inside the safe zone.
FILL_ADAPTIVE = 0.72
# Hairline stroke added around the subject, as a fraction of the icon size.
STROKE = 0.012
SS = 4  # supersampling factor for smooth masks and gradients


def cutout() -> Image.Image:
    """Return the bird on transparency, keeping the source's own framing.

    A plain white-key would punch holes in the bird's white body, so the sheet is
    flood-filled from the borders: enclosed white stays opaque, the outer sheet
    clears, and the dark outline survives as the bird's edge. The result is then
    trimmed back towards the subject by [FRAMING], keeping the crop square and
    centred on the subject so the headroom in the artwork survives.
    """
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    work = im.copy()
    bg = (255, 0, 255)
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w // 2, 0), (w // 2, h - 1)):
        ImageDraw.floodfill(work, seed, bg, thresh=30)

    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    src, dst = im.load(), out.load()
    for y in range(h):
        for x in range(w):
            if work.getpixel((x, y)) == bg:
                continue  # sheet: stay transparent
            r, g, b = src[x, y]
            dst[x, y] = (r, g, b, 255)

    box = out.getbbox()
    cw, ch = box[2] - box[0], box[3] - box[1]
    side = round(max(w, h) * FRAMING + max(cw, ch) * (1 - FRAMING))
    cx = (box[0] + box[2]) / 2
    cy = (box[1] + box[3]) / 2 + side * CENTER_OFFSET
    return out.crop((round(cx - side / 2), round(cy - side / 2), round(cx + side / 2), round(cy + side / 2)))


def stroke_color(subject: Image.Image) -> tuple[int, int, int]:
    """The darkest pixel of the subject: the colour of its own outline."""
    px = subject.load()
    dark = (255, 255, 255)
    for y in range(subject.height):
        for x in range(subject.width):
            r, g, b, a = px[x, y]
            if a and r + g + b < sum(dark):
                dark = (r, g, b)
    return dark


def outlined(subject: Image.Image) -> Image.Image:
    """Subject with a hairline stroke grown outwards from its alpha silhouette.

    The stroke is drawn at supersampled size and scaled back down with the
    subject, so it stays smooth even at the 24px densities.
    """
    w, h = subject.size
    mask = subject.getchannel("A").point(lambda v: 255 if v >= 96 else 0)
    grow = max(2, round(max(w, h) * STROKE))
    grown = mask.filter(ImageFilter.MaxFilter(2 * grow + 1))
    ring = Image.new("RGBA", (w, h), (*stroke_color(subject), 0))
    ring.putalpha(grown)
    return Image.alpha_composite(ring, subject)


def plate(size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), (*PLATE, 255))


def fit(subject: Image.Image, box: int) -> Image.Image:
    """Scale the subject so its longer side equals box, keeping aspect ratio."""
    scale = box / max(subject.size)
    return subject.resize(
        (max(round(subject.width * scale), 1), max(round(subject.height * scale), 1)),
        Image.LANCZOS,
    )


def centered(subject: Image.Image, size: int, bg: Image.Image | None = None) -> Image.Image:
    canvas = bg if bg is not None else Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(
        subject,
        ((size - subject.width) // 2, (size - subject.height) // 2),
        subject,
    )
    return canvas


def write(img: Image.Image, rel: str) -> None:
    out = RES / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print(f"{rel}: {img.width}x{img.height} {out.stat().st_size}B")


def main() -> None:
    bird = cutout()
    print("cutout size", bird.size)
    art = outlined(bird)

    # Legacy icons: white plate with a rounded-square edge (0.22 ~ iOS squircle).
    for dpi, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        big = size * SS
        icon = plate(big)
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, big - 1, big - 1), radius=round(big * 0.22), fill=255
        )
        subject = fit(art, round(big * FILL_LEGACY))
        icon.alpha_composite(centered(subject, big))
        icon.putalpha(mask)
        write(icon.resize((size, size), Image.LANCZOS), f"mipmap-{dpi}/ic_launcher.png")

    # Adaptive foreground: the bird on transparent, over the white background
    # layer declared by ic_launcher.xml / colors.xml.
    for dpi, size in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        subject = fit(art, round(size * FILL_ADAPTIVE))
        write(centered(subject, size), f"mipmap-{dpi}/ic_launcher_foreground.png")

    # Notification icon: the status-bar glyph. Android draws it as a mask and
    # paints it with the accent, so it must be a flat white silhouette on
    # transparency. The picture shown inside the notification itself is the app
    # icon, which the system supplies, so nothing extra is shipped for it.
    alpha = bird.getchannel("A").point(lambda v: 255 if v >= 96 else 0)
    silhouette = Image.new("RGBA", bird.size, (255, 255, 255, 0))
    silhouette.putalpha(alpha)
    for dpi, size in (("mdpi", 24), ("hdpi", 36), ("xhdpi", 48), ("xxhdpi", 72), ("xxxhdpi", 96)):
        # 1.16 padding: status-bar icons want a little breathing room.
        subject = fit(silhouette, round(size / 1.16))
        write(centered(subject, size), f"drawable-{dpi}/ic_notification.png")


if __name__ == "__main__":
    main()
