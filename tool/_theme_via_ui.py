"""Drive the theme radio through the app's own UI, then grab the next cold start.

Everything the app does between the tap and the kill is its own code path — the
same one a finger takes. Prints the splash colours of the relaunch.
"""

import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PKG = "com.example.untitled"
ACT = f"{PKG}/com.example.untitled.MainActivity"
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


def grab(tag: str, count: int = 5) -> list[tuple[int, int, int]]:
    out = []
    for i in range(1, count + 1):
        png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
        path = ROOT / "_audit" / f"{tag}_{i}.png"
        path.write_bytes(png)
        im = Image.open(path).convert("RGB")
        w, h = im.size
        out.append(im.getpixel((w // 2, h // 2)))
    return out


adb("shell", "cmd", "uimode", "night", "no")
adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")

for mode in sys.argv[1:]:
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", ACT)
    time.sleep(3.5)
    tap("设置", nodes())
    time.sleep(0.9)
    tap("主题与外观", nodes())
    time.sleep(0.9)
    tap("系统主题", nodes())
    time.sleep(1.1)
    picked = tap(mode, nodes())
    time.sleep(1.2)
    print(f"点了 {picked}")

    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.5)
    adb("shell", "logcat", "-c")
    adb("shell", "am", "start", "-n", ACT)
    print(f"  启动帧 {grab(f'grab_{mode}')}")
    time.sleep(1.5)
    log = [l.split("Jicun   : ")[-1].strip() for l in adb("shell", "logcat", "-d").splitlines() if "Jicun" in l]
    print(f"  日志 {log[:1]}")
