#!/usr/bin/env python3
"""Verify that the Android launch window matches the first Flutter frame.

Why this exists: a cold start shows the Android launch window until Flutter
draws its first frame. If the two differ, the hand-off is visible as a flash.
This measures that hand-off from the device instead of by eye.

It captures two screenshots:
  1. the launch window, sampled while Flutter is still starting up
  2. the settled first frame, after the UI has painted

then compares them per row. Because the launch window is sampled once the
window has finished animating in (see --delay), any remaining per-row delta is
a real mismatch in the background itself, not chrome or transition state.

Usage:
    python verify_launch_match.py
    python verify_launch_match.py --package com.videofix.jicun --skip 2500

Requires: adb on PATH or --adb, and Pillow (`pip install Pillow`).
Exit code 0 = match within tolerance, 1 = mismatch, 2 = setup problem.
"""

from __future__ import annotations

import argparse
import io
import statistics
import subprocess
import sys
import time

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")

TOLERANCE = 6  # max per-channel delta counted as a match, out of 255


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, **kw)


def screencap(adb: str) -> Image.Image:
    """Grab one frame. exec-out keeps the PNG binary intact; shell+pull does not."""
    out = run([adb, "exec-out", "screencap", "-p"]).stdout
    if not out.startswith(b"\x89PNG"):
        raise RuntimeError(f"screencap returned {len(out)} bytes, not a PNG")
    return Image.open(io.BytesIO(out)).convert("RGB")


def capture_pair(adb: str, package: str, settle: float, delay: float):
    run([adb, "shell", "am", "force-stop", package])
    time.sleep(0.8)
    run([adb, "shell", "am", "start", "-n", f"{package}/.MainActivity"])
    time.sleep(delay)
    launch = screencap(adb)
    time.sleep(settle)
    first = screencap(adb)
    return launch, first


def compare(launch: Image.Image, first: Image.Image, skip_bottom: int) -> int:
    w, h = launch.size
    if first.size != (w, h):
        print(f"FAIL  size changed between captures: {launch.size} vs {first.size}")
        return 2

    limit = h - skip_bottom
    deltas = []
    worst_row = (0, 0)
    for y in range(0, limit):
        # median across the row, so a few UI pixels cannot skew the row
        la = statistics.median(launch.getpixel((x, y))[0] for x in range(0, w, 16))
        fi = statistics.median(first.getpixel((x, y))[0] for x in range(0, w, 16))
        d = abs(la - fi)
        deltas.append(d)
        if d > worst_row[1]:
            worst_row = (y, d)

    over = sum(1 for d in deltas if d > TOLERANCE)
    print(f"compared rows 0..{limit - 1} of {w}x{h} (bottom {skip_bottom}px excluded)")
    print(f"  max delta   : {worst_row[1]}/255 at row {worst_row[0]}")
    print(f"  mean delta  : {statistics.mean(deltas):.2f}/255")
    print(f"  rows over {TOLERANCE}: {over} ({100 * over / len(deltas):.2f}%)")

    if over == 0:
        print("\nPASS  launch window matches the first frame across the gradient.")
        return 0
    print(f"\nFAIL  {over} rows differ by more than {TOLERANCE}/255.")
    return 1


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--adb", default="adb", help="path to adb (default: adb on PATH)")
    p.add_argument("--package", default="com.videofix.jicun")
    p.add_argument("--activity", default=None, help="default: <package>/.MainActivity")
    p.add_argument("--delay", type=float, default=1.5,
                   help="seconds after start before sampling the launch window; "
                        "below ~1.2s the window may still be animating in")
    p.add_argument("--settle", type=float, default=6.0,
                   help="seconds to wait for the first frame to settle")
    p.add_argument("--skip", type=int, default=0,
                   help="bottom pixels to exclude; 0 compares the whole screen")
    p.add_argument("--save", default=None, help="directory to keep the two captures in")
    args = p.parse_args()

    try:
        launch, first = capture_pair(args.adb, args.package, args.settle, args.delay)
    except (RuntimeError, FileNotFoundError) as exc:
        print(f"FAIL  could not capture: {exc}")
        return 2

    if args.save:
        import os
        os.makedirs(args.save, exist_ok=True)
        launch.save(os.path.join(args.save, "launch_window.png"))
        first.save(os.path.join(args.save, "first_frame.png"))
        print(f"saved captures to {args.save}")

    return compare(launch, first, args.skip)


if __name__ == "__main__":
    sys.exit(main())

