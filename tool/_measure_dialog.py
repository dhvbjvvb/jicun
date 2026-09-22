"""量「点一下 → 弹窗出现」花了多久。

    python tool/_measure_dialog.py 检查更新 --wait 仓库里还没有

[target] 是要点的节点(交给 _tap_ui.py 按 content-desc 找),[--wait] 是弹窗里
才会出现、页面上本来没有的那句话。每次都重新 dump 语义树,出现就停 —— dump 本身
要几百毫秒,所以量到的是**上界**,够用来分辨"1 秒内"和"8 秒"。
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _tap_ui import dump, nodes  # noqa: E402


def find(needle: str) -> str | None:
    for label, _bounds, _clickable in nodes(dump()):
        if needle in label:
            return label
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('target', nargs='?', default='检查更新')
    ap.add_argument('--wait', default='仓库里还没有')
    args = ap.parse_args()

    print('点之前:', (find(args.wait) or '(没有)')[:80])

    start = time.monotonic()
    subprocess.run(
        [sys.executable, str(Path(__file__).parent / '_tap_ui.py'), '--tap', args.target],
        check=True, capture_output=True,
    )
    for _ in range(40):
        label = find(args.wait)
        if label:
            print(f'{int((time.monotonic() - start) * 1000)}ms 后出现(含 dump 开销):')
            print(' ', label[:400])
            return 0
        time.sleep(0.2)
    print('8 秒内没出现', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
