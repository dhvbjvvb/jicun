"""Pick a theme mode through the app's own UI and sample the next cold start.

The device blocks `input tap` (vivo drops injected touch unless "USB debugging
(security settings)" is on) but accepts `input motionevent`, so the taps go out
as an explicit DOWN/UP pair. Samples two points of every launch frame: the left
edge (page background) and the centre of the screen (the bird, while a splash is
up). Reads the two theme keys straight out of shared_prefs after the tap, so a
lost write shows up instead of being guessed at.

HOME=1 backgrounds the app before killing it, which is what a finger does when
it swipes the app away instead of the harness force-stopping it.

Every launch goes through the component the launcher itself would start
(`cmd package resolve-activity`), not `.MainActivity`: the launch window is drawn
for the component being started, and since the theme now lives on two per-theme
launch entries, starting MainActivity would measure a path no user takes.

Usage: python tool/_theme_probe.py 深色 浅色
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PKG = "com.example.untitled"
PREFS = f"/data/data/{PKG}/shared_prefs/FlutterSharedPreferences.xml"
NODE = re.compile(
    r'content-desc="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
)


def adb(*args: str) -> str:
    return subprocess.run(["adb", *args], capture_output=True).stdout.decode(
        "utf-8", "replace"
    )


def launch_activity() -> str:
    """launcher 现在会启动哪个组件 —— 启动图跟着它走,探针也得从这儿起。"""
    out = adb(
        "shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.MAIN",
        "-c", "android.intent.category.LAUNCHER", PKG,
    )
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    return lines[-1] if lines else f"{PKG}/.MainActivity"


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


def shot(name: str) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    png = subprocess.run(
        ["adb", "exec-out", "screencap", "-p"], capture_output=True
    ).stdout
    path = ROOT / "_audit" / name
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    return im.getpixel((30, 900)), im.getpixel((w // 2, h // 2))


def prefs() -> str:
    return adb("shell", f"run-as {PKG} cat {PREFS}")


def card(table: dict[str, tuple[int, int]]) -> str:
    for key in table:
        if key.startswith("系统主题|"):
            return key.split("|")[-1]
    return "-"


def keys(xml: str) -> str:
    native = re.search(r'name="native\.themeMode">([^<]*)<', xml)
    dart = re.search(r'name="flutter\.ui\.themeMode">([^<]*)<', xml)
    return (f"native={native.group(1) if native else '-'} "
            f"dart={dart.group(1) if dart else '-'}")


def jicun_log(tail: int = 2) -> list[str]:
    return [
        line.split("Jicun   : ")[-1].strip()
        for line in adb("shell", "logcat", "-d").splitlines()
        if "Jicun" in line
    ][-tail:]


adb("shell", "cmd", "uimode", "night", "no")
adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")

for mode in sys.argv[1:]:
    adb("shell", "am", "force-stop", PKG)
    time.sleep(1)
    adb("shell", "am", "start", "-n", launch_activity())
    time.sleep(3.5)
    # The app restores the page it was left on; pop back to the settings tab.
    for _ in range(3):
        table = nodes()
        if not tap(table, "设置"):
            adb("shell", "input", "keyevent", "4")
            time.sleep(0.8)
        else:
            break
    time.sleep(1.0)
    picked = tap(nodes(), "主题与外观")
    time.sleep(1.0)
    picked += "/" + tap(nodes(), "系统主题")
    time.sleep(1.2)
    for _ in range(3):
        table = nodes()
        picked += "/" + tap(table, mode)
        time.sleep(1.2)
        if card(nodes()) == mode:
            break
        tap(nodes(), "系统主题")
        time.sleep(1.2)
    picked += f"|卡片={card(nodes())}"
    after_tap = keys(prefs())

    if os.environ.get("HOME"):
        # A finger swipes the app away: it goes to the background first.
        adb("shell", "input", "keyevent", "3")
        time.sleep(1.2)

    adb("shell", "am", "force-stop", PKG)
    time.sleep(0.5)
    entry = launch_activity()
    adb("shell", "logcat", "-c")
    adb("shell", "am", "start", "-n", entry)
    frames = [shot(f"probe_{mode}_{i}.png") for i in range(1, 5)]
    time.sleep(1.5)
    print(f"[{mode}] 点了 {picked}")
    print(f"  点完偏好 {after_tap}")
    print(f"  launcher 入口 {entry}")
    print(f"  冷启动帧 {frames}")
    print(f"  冷启动日志 {jicun_log(1)}")
