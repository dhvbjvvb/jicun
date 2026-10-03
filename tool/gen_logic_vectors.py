#!/usr/bin/env python3
"""Exports the downloader's pure-logic test vectors as JSON.

Why generate from Dart instead of hand-writing the JSON: a wrong vector is worse than
no vector -- both ports would happily agree with each other. There is exactly one
hand-defined place (the case tables below, numbers taken from the comments next to the
functions in NativeDownloader.kt), and Dart / Kotlin both read the same JSON.

Usage (from the repo root):

    python tool/gen_logic_vectors.py            # verify the JSON matches the tables
    python tool/gen_logic_vectors.py --write    # rewrite it

Outputs: tool/download_logic_vectors.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VECTORS = ROOT / "tool" / "download_logic_vectors.json"


SIZES = [1, 100, 4095, 4096, 4097, 1 << 20, 153 << 20]
CHUNKS = [1, 1024, 4096, 1 << 20]
TAIL = 32 << 20
TAIL_CHUNK = 1 << 20


def claimed(claim, size, chunk):
    start = claim * chunk
    if start >= size:
        return None
    return [start, min(size, start + chunk) - 1]


def claimed_tail(claim, size, chunk, tail, tail_chunk):
    tail_from = size - tail if size > tail * 2 else size
    head_count = (tail_from + chunk - 1) // chunk
    if claim < head_count:
        return claimed(claim, tail_from, chunk)
    if tail_from >= size:
        return None
    t = claimed(claim - head_count, size - tail_from, tail_chunk)
    if t is None:
        return None
    return [t[0] + tail_from, t[1] + tail_from]


def resume(written, offset, end):
    return min(offset + written, end + 1)


def rotate(start, written, wanted, elapsed, budget):
    return start >= 0 and written < wanted and elapsed >= budget


def whole_file(code, start, end, length):
    return code == 200 and start == 0 and end >= 0 and length == end + 1


def lanes(l, items):
    return l if items <= 1 else max(1, l // items)


class Attempts:
    def __init__(self, stall_limit, attempt_limit):
        self.stall_limit = stall_limit
        self.attempt_limit = attempt_limit
        self.attempts = 0
        self.stalls = 0

    def note_failure(self, progress):
        self.attempts += 1
        self.stalls = 0 if progress > 0 else self.stalls + 1
        return self.stalls < self.stall_limit and self.attempts < self.attempt_limit

    def delay_ms(self):
        return min(200 << max(0, min(self.stalls - 1, 4)), 2000)


def attempt_run(stall_limit, attempt_limit, progress):
    a = Attempts(stall_limit, attempt_limit)
    steps = []
    for p in progress:
        retry = a.note_failure(p)
        steps.append({"progress": p, "retry": retry, "delayMs": a.delay_ms()})
    return {
        "steps": steps,
        "attempts": a.attempts,
        "stalls": a.stalls,
        "finalDelayMs": a.delay_ms(),
    }


def build():
    chunk_cases = []
    for size in SIZES:
        for chunk in CHUNKS:
            claims = (size + chunk - 1) // chunk
            # 迭代验证也是 O(claims),太大的组合(153MB 按 1 字节切是 1.6 亿次)不列,
            # 覆盖性和段大小无关,小组合已经说明问题。
            if claims > 200000:
                continue
            # 大文件一律不给具体的行:认领次数上几十万,JSON 会肥到没人看。
            # 那种用例只锁 claims 数、"每段严丝合缝"和总覆盖(拍平在测试里迭代验证)。
            if claims > 64:
                chunk_cases.append({
                    "name": "plain-%d-%d" % (size, chunk),
                    "size": size,
                    "chunk": chunk,
                    "rows": None,
                    "covers": True,
                    "claims": claims,
                })
                continue
            rows = []
            claim = 0
            covered = 0
            while True:
                c = claimed(claim, size, chunk)
                if c is None:
                    break
                rows.append(c)
                covered += c[1] - c[0] + 1
                claim += 1
            chunk_cases.append({
                "name": "plain-%d-%d" % (size, chunk),
                "size": size,
                "chunk": chunk,
                "rows": rows,
                "covers": covered == size,
                "claims": len(rows),
            })

    tail_cases = []
    for size in SIZES:
        rows = []
        claim = 0
        covered = 0
        while True:
            c = claimed_tail(claim, size, 4 << 20, TAIL, TAIL_CHUNK)
            if c is None:
                break
            # 153MB 那条尾巴会被切成 32 段,再加上前面的大段 —— 行数还在几十以内,
            # 全部留着(和 chunkCases 不同,这里没有几十万行那种情况)。
            rows.append(c)
            covered += c[1] - c[0] + 1
            claim += 1
        tail_cases.append({
            "name": "tail-%d" % size,
            "size": size,
            "chunk": 4 << 20,
            "tail": TAIL,
            "tailChunk": TAIL_CHUNK,
            "rows": rows,
            "covers": covered == size,
            "claims": len(rows),
        })

    resume_cases = [
        {"written": w, "offset": o, "end": e, "expected": resume(w, o, e)}
        for (w, o, e) in [(0, 100, 199), (50, 100, 199), (100, 100, 199),
                          (999, 100, 199), (1, 0, 0)]
    ]
    rotate_cases = [
        {"start": s, "written": w, "wanted": wa, "elapsed": el,
         "budget": b, "expected": rotate(s, w, wa, el, b)}
        for (s, w, wa, el, b) in [(0, 10, 100, 10000, 10000),
                                  (0, 100, 100, 10000, 10000),
                                  (0, 10, 100, 9999, 10000),
                                  (-1, 10, -1, 99999, 10000),
                                  (5, 0, 8, 20000, 5000)]
    ]
    range_cases = [
        {"code": c, "start": s, "end": e, "contentLength": l,
         "expected": whole_file(c, s, e, l)}
        for (c, s, e, l) in [(200, 0, 2497215, 2497216),
                             (200, 0, 2497215, 100),
                             (200, 4096, 8191, 4096),
                             (206, 0, 999, 1000),
                             (200, -1, -1, 100),
                             (200, 0, 0, 1)]
    ]
    lane_cases = [
        {"lanes": l, "items": i, "expected": lanes(l, i)}
        for (l, i) in [(32, 1), (32, 4), (32, 100), (1, 4), (3, 2), (1, 1)]
    ]
    attempt_cases = [
        {
            "name": "有进展就清零",
            "stallLimit": 4,
            "attemptLimit": 40,
            "expected": attempt_run(4, 40, [100, 0, 0, 0, 0]),
        },
        {
            "name": "硬上限兜住每次只前进一点",
            "stallLimit": 1000,
            "attemptLimit": 40,
            "expected": attempt_run(1000, 40, [1] * 40),
        },
        {
            "name": "退避 200 起翻倍封顶 2s",
            "stallLimit": 1000,
            "attemptLimit": 1000,
            "expected": attempt_run(1000, 1000, [0] * 8),
        },
    ]

    return {
        "note": "下载器纯逻辑的测试向量。Dart/Kotlin 共用;生成见 tool/gen_logic_vectors.py。",
        "chunkCases": chunk_cases,
        "tailCases": tail_cases,
        "resumeCases": resume_cases,
        "rotateCases": rotate_cases,
        "rangeCases": range_cases,
        "laneCases": lane_cases,
        "attemptCases": attempt_cases,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="下载器纯逻辑测试向量生成/校验")
    ap.add_argument("--write", action="store_true", help="写文件(默认只校验)")
    args = ap.parse_args()

    data = build()
    text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"

    if args.write:
        VECTORS.write_text(text, encoding="utf-8")
        print("wrote", VECTORS.relative_to(ROOT))
        return 0

    if not VECTORS.exists():
        print("缺向量文件:" + str(VECTORS) + "(先跑 --write)", file=sys.stderr)
        return 1
    if VECTORS.read_text(encoding="utf-8") != text:
        print("向量和实现不一致:重跑 python tool/gen_logic_vectors.py --write", file=sys.stderr)
        return 1
    print("向量与实现一致(" + str(VECTORS.relative_to(ROOT)) + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
