"""Pick 浅色 / 深色 in 设置 → 主题与外观 → 系统主题 and sample the splash each way."""

import re
import subprocess
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


def mid(name: str) -> tuple[int, int, int]:
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    path = ROOT / "_audit" / name
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    return im.getpixel((w // 2, h // 2))


adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")

for mode in ("深色", "浅色"):
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", ACT)
    time.sleep(4)
    tap("设置", nodes())
    time.sleep(1)
    tap("主题与外观", nodes())
    time.sleep(1)
    tap("系统主题", nodes())
    time.sleep(1.2)
    print(f"点 {tap(mode, nodes())}")
    time.sleep(2.5)
    print("  切换后界面", mid(f"cyc_{mode}_ui.png"))

    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "logcat", "-c")
    adb("shell", "am", "start", "-n", ACT)
    frames = [mid(f"cyc_{mode}_{i}.png") for i in range(1, 5)]
    time.sleep(2)
    log = adb("shell", "logcat", "-d")
    seen = [l.split("Jicun   : ")[-1].strip() for l in log.splitlines() if "Jicun" in l]
    print(f"  冷启动帧 {frames}")
    print(f"  日志 {seen[:2]}")
