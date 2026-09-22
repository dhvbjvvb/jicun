"""按 uiautomator 的实际节点边界点按,别再靠肉眼猜坐标。

    python tool/_tap_ui.py --list                  # 列出当前可点节点
    python tool/_tap_ui.py --tap 检查更新           # 点 content-desc 含该子串的节点

uiautomator 的 dump 是 UTF-8,但 adb 拉下来在 PowerShell 里读会变成乱码,
所以这里直接读文件、按 utf-8 解析。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def dump() -> ET.Element:
    subprocess.run(
        ['adb', 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml'],
        check=True, capture_output=True,
    )
    local = Path(tempfile.gettempdir()) / 'ui_tap.xml'
    subprocess.run(['adb', 'pull', '/sdcard/ui.xml', str(local)],
                   check=True, capture_output=True)
    return ET.fromstring(local.read_text(encoding='utf-8'))


def nodes(root: ET.Element) -> list[tuple[str, str, bool]]:
    out = []
    for node in root.iter('node'):
        desc = node.get('content-desc') or ''
        text = node.get('text') or ''
        clickable = node.get('clickable') == 'true'
        if desc or text:
            out.append((desc or text, node.get('bounds'), clickable))
    return out


def center(bounds: str) -> tuple[int, int]:
    x0, y0, x1, y1 = (int(v) for v in re.findall(r'\d+', bounds))
    return (x0 + x1) // 2, (y0 + y1) // 2


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--tap')
    args = ap.parse_args()

    root = dump()
    if args.list or not args.tap:
        for label, bounds, clickable in nodes(root):
            print(f'{"可点" if clickable else "  "}  {bounds:24} {label}')
        return 0

    for label, bounds, _ in nodes(root):
        if args.tap in label:
            x, y = center(bounds)
            print(f'点 {label} @ ({x},{y})  {bounds}')
            subprocess.run(['adb', 'shell', 'input', 'tap', str(x), str(y)], check=True)
            return 0
    print(f'没找到含「{args.tap}」的节点', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
