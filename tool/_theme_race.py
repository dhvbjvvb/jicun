"""Stress the "pick a mode, kill the app at once, relaunch" race.

Runs the app's own radio through several light/dark flips, killing the process
immediately after each pick, and reports the splash colour of the relaunch
against the flush timeout the plugin used. The mode the native side mirrored is
also read straight out of shared_prefs, so a lost write shows up as a missing or
stale entry rather than a guess.
"""

import re
import subprocess
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PKG = "com.example.untitled"
ACT = f"{PKG}/com.example.untitled.MainActivity"
PREFS = "/data/data/com.example.untitled/shared_prefs/FlutterSharedPreferences.xml"
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


def shot(name: str) -> tuple[int, int, int]:
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    path = ROOT / "_audit" / name
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    return im.getpixel((w // 2, h // 2))


def prefs_mode() -> str:
    xml = adb("shell", "cat", PREFS)
    native = re.search(r'name="native\.themeMode">([^<]*)<', xml)
    dart = re.search(r'name="flutter\.ui\.themeMode">([^<]*)<', xml)
    return f"native={native.group(1) if native else '-'} dart={dart.group(1) if dart else '-'}"


def open_radio() -> dict[str, tuple[int, int]]:
    tap("设置", nodes())
    time.sleep(1)
    tap("主题与外观", nodes())
    time.sleep(1)
    tap("系统主题", nodes())
    time.sleep(1.2)
    return nodes()


adb("shell", "cmd", "uimode", "night", "no")
adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")

for round_no, mode in enumerate(("深色", "浅色", "深色", "浅色"), start=1):
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", ACT)
    time.sleep(3.5)
    picked = tap(mode, open_radio())
    time.sleep(1.0)  # 只等界面刷出来,不额外等落盘

    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.4)
    adb("shell", "logcat", "-c")
    adb("shell", "am", "start", "-n", ACT)
    frames = [shot(f"race_{round_no}_{i}.png") for i in range(1, 5)]
    time.sleep(1.5)
    log = [l.split("Jicun   : ")[-1].strip() for l in adb("shell", "logcat", "-d").splitlines() if "Jicun" in l]
    print(f"[{round_no}] 点 {picked} -> 偏好 {prefs_mode()}")
    print(f"      启动帧 {frames}")
    print(f"      日志 {log[:1]}")
