"""One round of: launch → pick 深色 in the app → kill → relaunch, keeping the frames.

Unlike the other probes this one does not restart the app before picking the mode,
so it follows the same path a person takes when the app is already open.
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
NODE = re.compile(r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')


def adb(*args: str) -> str:
    return subprocess.run(["adb", *args], capture_output=True).stdout.decode("utf-8", "replace")


def nodes() -> dict[str, tuple[int, int]]:
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    out: dict[str, tuple[int, int]] = {}
    for desc, x1, y1, x2, y2 in NODE.findall(xml):
        label = desc.replace("&#10;", "|").strip()
        if label:
            out[label] = ((int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2)
    return out


def tap(label: str, table: dict[str, tuple[int, int]]) -> str:
    for key, (x, y) in table.items():
        if key.startswith(label):
            adb("shell", "input", "tap", str(x), str(y))
            return key
    return ""


def shot(tag: str, i: int) -> tuple[int, int, int]:
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    path = ROOT / "_audit" / f"{tag}_{i}.png"
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    return im.getpixel((w // 2, h // 2))


tag = sys.argv[1]
adb("shell", "cmd", "uimode", "night", "no")
adb("shell", "am", "force-stop", PKG)
time.sleep(1)
adb("shell", "am", "start", "-n", ACT)
time.sleep(3.5)

tap("设置", nodes())
time.sleep(0.9)
tap("主题与外观", nodes())
time.sleep(0.9)
print("主题页卡片", [k for k in nodes() if k.startswith("系统主题")])
tap("系统主题", nodes())
time.sleep(1.1)
print("选项", {k: v for k, v in nodes().items() if k in ("跟随系统", "浅色", "深色")})
print("点了", tap("深色", nodes()))
time.sleep(2.0)
print("切完之后界面", shot(f"{tag}_after", 1))
print("主题页卡片", [k for k in nodes() if k.startswith("系统主题")])

adb("shell", "am", "force-stop", PKG)
time.sleep(0.6)
adb("shell", "logcat", "-c")
adb("shell", "am", "start", "-n", ACT)
for i in range(1, 6):
    print(f"启动帧{i}", shot(f"{tag}_launch", i))
time.sleep(1.5)
print("日志", [l.split("Jicun   : ")[-1].strip() for l in adb("shell", "logcat", "-d").splitlines() if "Jicun" in l][:2])
