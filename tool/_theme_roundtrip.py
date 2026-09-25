"""Pick 深色 / 浅色 in the app and read back what the next cold start saw."""

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
    p = subprocess.run(["adb", *args], capture_output=True)
    return (p.stdout or b"").decode("utf-8", "replace")


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


def shot_colour(name: str) -> tuple[int, int, int]:
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    path = ROOT / "_audit" / name
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    return im.getpixel((w // 2, h // 2))


def boot() -> None:
    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.8)
    adb("shell", "am", "start", "-n", ACT)
    time.sleep(4)


def open_radio() -> dict[str, tuple[int, int]]:
    table = nodes()
    tap("设置", table)
    time.sleep(1)
    table = nodes()
    tap("主题与外观", table)
    time.sleep(1)
    table = nodes()
    tap("系统主题", table)
    time.sleep(1.2)
    return nodes()


for mode in ("深色", "浅色", "深色"):
    boot()
    table = open_radio()
    picked = tap(mode, table)
    time.sleep(2.5)
    print(f"选 {picked} -> 界面 {shot_colour('rt_ui.png')}")

    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.8)
    adb("shell", "logcat", "-c")
    adb("shell", "am", "start", "-n", ACT)
    time.sleep(0.6)
    frames = [shot_colour(f"rt_{mode}_{i}.png") for i in range(1, 4)]
    time.sleep(2)
    log = adb("shell", "logcat", "-d")
    seen = [l.split("Jicun   : ")[-1].strip() for l in log.splitlines() if "Jicun" in l]
    print(f"  冷启动帧 {frames}")
    print(f"  日志 {seen[:3]}")

    # 再启动一次,进设置卡片看它记的是哪一档
    boot()
    table = open_radio()
    print("  卡片值", [k for k in table if k.startswith("系统主题")])
