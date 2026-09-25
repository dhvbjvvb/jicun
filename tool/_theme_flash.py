"""Watch what the screen does while the theme radio is tapped.

Records the app during the tap and reports the colour at two points (a page
corner and the middle of the screen) per frame, so a splash flashing back over
the UI shows up as a flat #434343 / #CDDCDC run in the middle of the app.

Usage: python tool/_theme_flash.py 浅色
"""

import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PKG = "com.videofix.jicun"
ACT = f"{PKG}/com.videofix.jicun.MainActivity"
NODE = re.compile(
    r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
)


def adb(*args: str) -> str:
    return subprocess.run(["adb", *args], capture_output=True).stdout.decode(
        "utf-8", "replace"
    )


def nodes() -> dict[str, tuple[int, int]]:
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    out: dict[str, tuple[int, int]] = {}
    for desc, x1, y1, x2, y2 in NODE.findall(xml):
        label = desc.replace("&#10;", "|").strip()
        if label:
            out[label] = ((int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2)
    return out


def tap(table: dict[str, tuple[int, int]], label: str) -> str:
    for key, (x, y) in table.items():
        if key.startswith(label):
            adb("shell", "input", "motionevent", "DOWN", str(x), str(y))
            adb("shell", "input", "motionevent", "UP", str(x), str(y))
            return key
    return ""


adb("shell", "cmd", "uimode", "night", "no")
adb("shell", "am", "force-stop", PKG)
time.sleep(1)
adb("shell", "am", "start", "-n", ACT)
time.sleep(3.5)
tap(nodes(), "设置")
time.sleep(1.0)
tap(nodes(), "主题与外观")
time.sleep(1.0)
tap(nodes(), "系统主题")
time.sleep(1.2)

adb("shell", "rm", "-f", "/sdcard/flash.mp4")
rec = subprocess.Popen(
    ["adb", "shell", "screenrecord", "--time-limit", "8",
     "--bit-rate", "20000000", "/sdcard/flash.mp4"],
    stdout=subprocess.DEVNULL,
)
time.sleep(1.5)
picked = tap(nodes(), sys.argv[1])
print(f"点了 {picked}")
time.sleep(6.5)
rec.wait()
adb("pull", "/sdcard/flash.mp4", str(ROOT / "_splashfix" / "flash.mp4"))

frames = ROOT / "_splashfix" / "flash"
frames.mkdir(exist_ok=True)
subprocess.run(
    ["ffmpeg", "-v", "error", "-y", "-i", str(frames.parent / "flash.mp4"),
     "-vf", "fps=30", str(frames / "f_%04d.png")],
    check=True,
)
prev = None
for png in sorted(frames.glob("f_*.png")):
    im = Image.open(png).convert("RGB")
    w, h = im.size
    edge = im.getpixel((30, 900))
    mid = im.getpixel((w // 2, h // 2))
    if edge != prev:
        print(f"  {png.name} edge={edge} mid={mid}")
        prev = edge
