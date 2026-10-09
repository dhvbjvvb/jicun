#!/usr/bin/env python3
"""仓库卫生:不该跟着公开仓库走的东西,别靠人眼发现。

为什么要有这个脚本 —— 两件真事都是翻文件翻出来的,不是被谁拦住的:

  * tool/run_tests.ps1 的自检夹具里写进了开发机的绝对路径(D:/AndroidStudio/APP/untitled,
    16 处):输出解析的判据只看「绝对路径 → 相对仓库路径」的转换,根目录写什么都一样,
    写本机路径纯粹是抄日志时顺手带进来的;
  * pubspec.lock 的 96 行 hosted url 是本机 pub 镜像(pub.flutter-io.cn),来自这台机器的
    PUB_HOSTED_URL —— 它会决定 CI 从哪儿拉包。

两件都不致命,但都会跟着仓库走,而且只有人正好看到那一行才会发现。这个脚本把它们变成门。

判据(每条都写清为什么):

  1. 本机痕迹:受版本控制的文本文件里不许出现开发机专有的字符串(见 MACHINE_MARKERS);
  2. 依赖源:pubspec.lock 里所有 hosted `url:` 必须是 https://pub.dev —— 镜像或私有源一进
     库,所有人的构建与 CI 都跟着它走;
  3. 密钥与口令:key.properties / *.jks / *.keystore / lib/secrets.dart 不许被跟踪
     (.gitignore 已经挡了一道,这里是第二道:--force、或者谁改了忽略规则时能挡住);
  4. SDK 版本单一来源:ci.yml 里钉的 `flutter-version:` 必须等于 .flutter-version。两边各改
     各的正是格式门变红的原因(实测:Dart 3.13.3 → 3.13.5 之后 dart format 对没改过的文件
     也要求重排)。

另外**只提示、不算失败**:本机 flutter 版本与 .flutter-version 不一致。那句话正好解释了
「本地 dart format 红、CI 绿」这种最难归因的场面,早点说出来比事后猜强。

用法(仓库根,CI 里也是这么跑):

    python tool/check_repo_hygiene.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SELF = Path(__file__).resolve()

# 只扫文本:图片/音频/apk 里出现什么都不算数。
TEXT_SUFFIXES = {
    ".dart", ".kt", ".java", ".py", ".ps1", ".sh", ".bat", ".cmd",
    ".json", ".yaml", ".yml", ".md", ".txt", ".xml", ".gradle", ".kts",
    ".properties", ".pro", ".toml", ".lock", ".gitignore", ".gitattributes",
}

# 开发机专有、仓库里没有任何正当理由出现的字符串。每条都要说得出为什么。
MACHINE_MARKERS = {
    "AndroidStudio": "IDE 安装目录,只有开发机才有(自检夹具里写进去过 16 处)",
    "pub.flutter-io.cn": "本机 pub 镜像,不是 pub.dev(lock 里出现过 96 行)",
    "storage.flutter-io.cn": "本机 flutter 存储镜像,同上",
}

# 密钥与口令。已经在 .gitignore 里挡了一道;这里是第二道。
SECRET_FILES = ("android/key.properties", "lib/secrets.dart")
SECRET_SUFFIXES = (".jks", ".keystore")

LOCK = ROOT / "pubspec.lock"
ALLOWED_HOSTED = "https://pub.dev"
SDK_FILE = ROOT / ".flutter-version"
CI_FILE = ROOT / ".github" / "workflows" / "ci.yml"
URL_RE = re.compile(r'^\s+url:\s*"?(?P<url>[^"\s]+)"?\s*$')
CI_SDK_RE = re.compile(r"^\s*flutter-version:\s*(?P<version>\S+)\s*$")
LOCAL_SDK_RE = re.compile(r"^Flutter\s+(?P<version>\S+)")


def tracked_files() -> list[str]:
    # -z + 显式 UTF-8:仓库里有中文文件名,git 默认按 core.quotepath 转义,而 Python 在
    # Windows 上默认按 GBK 解码 —— 那样这里会直接崩(实测踩过一次)。
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=True,
    ).stdout
    return [line for line in out.split("\0") if line]


def read_text(relative: str) -> str | None:
    try:
        return (ROOT / relative).read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        # 二进制或者读不动:不是这个脚本要管的东西。
        return None


def check_machine_markers(files: list[str]) -> list[str]:
    problems: list[str] = []
    for relative in files:
        path = ROOT / relative
        if path.resolve() == SELF or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if relative == LOCK.name:
            # lock 由 check_lock() 专管:同一个问题报两遍只会淹掉真正要看的那几行。
            continue
        text = read_text(relative)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for marker, why in MACHINE_MARKERS.items():
                if marker in line:
                    problems.append(f"{relative}:{number}  带本机痕迹 {marker}({why})")
    return problems


def check_lock() -> list[str]:
    problems: list[str] = []
    if not LOCK.is_file():
        return [f"{LOCK.name} 不存在?"]
    for number, line in enumerate(LOCK.read_text(encoding="utf-8").splitlines(), 1):
        found = URL_RE.match(line)
        if found and found.group("url") != ALLOWED_HOSTED:
            problems.append(
                f"pubspec.lock:{number}  hosted 源是 {found.group('url')},"
                f"只允许 {ALLOWED_HOSTED}(镜像/私有源一进库,别人的构建也跟着走)"
            )
    return problems


def check_secrets(files: list[str]) -> list[str]:
    problems: list[str] = []
    for relative in files:
        if relative in SECRET_FILES or relative.endswith(SECRET_SUFFIXES):
            problems.append(f"{relative}  被跟踪了:密钥/口令不该进版本库")
    return problems


def ci_sdk_version() -> str | None:
    if not CI_FILE.is_file():
        return None
    for line in CI_FILE.read_text(encoding="utf-8").splitlines():
        found = CI_SDK_RE.match(line)
        if found:
            return found.group("version")
    return None


def check_sdk_source() -> tuple[list[str], str | None]:
    if not SDK_FILE.is_file():
        return [".flutter-version 不存在:它就是「这个仓库按哪个 SDK 对齐的」那一个来源"], None
    pinned = SDK_FILE.read_text(encoding="utf-8").strip()
    if not pinned:
        return [".flutter-version 是空的"], None
    ci = ci_sdk_version()
    if ci is None:
        return [".github/workflows/ci.yml 里没有 flutter-version:(应当钉住 .flutter-version 那个值)"], pinned
    if ci != pinned:
        return [
            f"ci.yml 钉的 flutter-version 是 {ci},.flutter-version 写的是 {pinned} —— "
            "两处必须一致(格式门就是被 SDK 版本带红的)"
        ], pinned
    return [], pinned


def local_sdk_note(pinned: str | None) -> str | None:
    """本机 SDK 与钉住的版本不一致时提示一句 —— 不算失败。"""
    if pinned is None:
        return None
    try:
        out = subprocess.run(
            ["flutter", "--version"],
            cwd=ROOT,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    found = LOCAL_SDK_RE.search(out.strip())
    if not found or found.group("version") == pinned:
        return None
    return (
        f"提示:本机 flutter 是 {found.group('version')},仓库对齐的是 {pinned}。"
        "版本不一样时本地 dart format 会对没改过的文件也要求重排(CI 用的是钉住那个版本),"
        "别慌,也别顺手把整仓重排一遍 —— 先确认是不是这个原因。"
    )


def main() -> int:
    files = tracked_files()
    problems: list[str] = []
    problems += check_machine_markers(files)
    problems += check_lock()
    problems += check_secrets(files)
    sdk_problems, pinned = check_sdk_source()
    problems += sdk_problems

    for problem in problems:
        print(problem)
    note = local_sdk_note(pinned)
    if note:
        print(f"\n{note}")
    if problems:
        print(f"\n{len(problems)} 处仓库卫生问题(判据见本文件头部)。")
        return 1
    print(f"仓库卫生 OK:扫了 {len(files)} 个受版本控制的文件。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
