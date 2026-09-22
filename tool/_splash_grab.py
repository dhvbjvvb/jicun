"""Cold-start the app and grab frames back to back, recording each one's colours.

Used to catch the splash window: it lives a few hundred milliseconds, so a single
screencap after the launch is a coin flip. Prints a line per frame and keeps the
PNGs so the exact frame can be looked at.
"""

import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PKG = "com.example.untitled"
ACT = f"{PKG}/com.example.untitled.MainActivity"


def adb(*args: str) -> str:
    return subprocess.run(["adb", *args], capture_output=True).stdout.decode("utf-8", "replace")


tag = sys.argv[1] if len(sys.argv) > 1 else "grab"
adb("shell", "am", "force-stop", PKG)
time.sleep(0.8)
adb("shell", "logcat", "-c")
adb("shell", "am", "start", "-n", ACT)
for i in range(1, 7):
    png = subprocess.run(["adb", "exec-out", "screencap", "-p"], capture_output=True).stdout
    path = ROOT / "_audit" / f"{tag}_{i}.png"
    path.write_bytes(png)
    im = Image.open(path).convert("RGB")
    w, h = im.size
    print(f"{tag} {i} corner={im.getpixel((8, 8))} top={im.getpixel((w // 2, 300))} mid={im.getpixel((w // 2, h // 2))}")
print(adb("shell", "logcat", "-d"))
