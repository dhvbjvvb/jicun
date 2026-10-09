# 跑 flutter test:整套先跑一遍,再把「第一段里挂了嫌疑」的文件单独重跑,最后给汇总。
#
# 为什么要这么跑:Windows 上的 flutter_tester.exe 有一条引擎级缺陷 —— 它以
# 0xc0000005(访问违例,偏移恒定 0x35aaf0)静默杀掉整个测试进程,一次带走同一文件里
# 剩下的几十条用例。2026-10-06 在本机实测到的样子:
#
#   * 整套跑(并发默认)每轮 450 条上下,固定崩 4~6 个进程 —— 整套跑几乎不可能绿;
#   * 单文件跑,38 个文件里崩 5 个(约 13%);被杀的那个文件单独再跑又是绿的;
#   * 概率跟「跑了多少条用例」有关(整套约 1%/条);同一时段连跑 168 个只有一条用例的
#     空白工程进程,一次都没崩;
#   * 跟本仓库代码无关:`flutter create` 出来的空白工程也崩过一次;
#   * 跟并发无关(1 / 2 / 12 都崩),也跟资源无关(内存、句柄全程平稳)。
#
# 所以跑法是两段:第一段整套跑一遍(快,和平时敲的那条命令一致),第二段只把第一段里
# 「被杀」和「报失败」的文件单独跑一遍。逐文件跑(-PerFile)保留着:爆炸半径最小,只是慢
# 几倍,适合想一边跑一边看输出的场合。
#
# **只对「tester 崩了」重跑**。断言/异常失败一律直接 FAIL —— 无脑重跑会把「偶尔挂一次」
# 的真 bug 抹成绿色,那是拿重跑当遮羞布。判据见 [Test-RunnerCrashed]。
#
# 改过判据或输出解析就扫一下它:.\tool\run_tests.ps1 -SelfCheck(只跑自检,不跑测试)。
#
# 每个文件默认给 3 次机会、两次之间歇 3 秒(-Retry / -PauseSeconds 可调):崩溃是成阵的,
# 同一分钟里连着跑往往一条都出不来,隔几秒常常就过了。
param(
  [int]$Retry = 3,
  [int]$PauseSeconds = 3,
  [string]$Path = 'test',
  [int]$Concurrency = 0,
  [switch]$Coverage,
  [switch]$PerFile,
  [switch]$SelfCheck
)

# 这次失败是「tester 崩了(可重跑)」还是「真的失败(不许重跑)」?
#
# 判据是**看有没有失败标记**,而不是看有没有 `did not complete`:后者只是崩溃的一种
# 形态。实测崩得最干脆的那次,输出只剩一行 `loading test/xxx_test.dart`,连 `[E]` 都
# 没来得及打 —— 那时按「没有 did not complete 就是真失败」会判反,把崩溃当成假失败。
#
# 反过来,真失败**一定**留标记:断言(Expected/Actual/TestFailure)、未捕获异常、
# 编译/加载失败(Failed to load)、或者报告器打的 `[E]` 失败行。两条都不沾的非零退出
# 只可能是进程没了,按崩溃算、放它重跑。
#
# **「进程没了」有一句话专属于它,必须排在标记表前面查**:`Connection closed before
# test suite loaded.` —— 加载期就被杀时 flutter 报的是
# `Failed to load "...": Connection closed before test suite loaded.`,它同时带
# `Failed to load` 和 `[E]`,先查标记就会当成真失败 —— 全量跑时真撞上了:某个文件在
# loading 阶段被杀,判成真失败不重跑,单独跑 17/17 反而全绿。断言失败和编译错误都不会
# 说 connection closed,这句话只可能是进程死了。
function Test-RunnerCrashed([string]$Text) {
  if ($Text -match 'did not complete') { return $true }
  if ($Text -match 'Connection closed before test suite loaded') { return $true }
  if ($Text -match 'Expected:|Actual:|TestFailure|EXCEPTION CAUGHT|Unhandled exception|Failed to load|\[E\]') {
    return $false
  }
  return $true
}

# flutter 打的路径是绝对路径 + 正斜杠(D:/x/test/y_test.dart);这里换成相对仓库根的写法。
function ConvertTo-RelPath([string]$Path, [string]$Root) {
  $p = $Path.Replace('\', '/')
  if ($p -notmatch '^[A-Za-z]:/') { return $p }
  try { return [IO.Path]::GetRelativePath($Root, $p).Replace('\', '/') } catch { return $p }
}

# 从一次 flutter test 的输出里挑出「挂了嫌疑」的文件:
#   KILLED —— 进程被杀(跑到一半 did not complete,或加载期 connection closed);
#   FAILED —— 带 [E] 的失败行,或加载失败(编译错误那种 Failed to load)。
#
# 两种都不能直接判死:KILLED 单独重跑一遍就可能是绿的;FAILED 要单独重跑一次才能拿到
# 干净、不被别的文件搅在一起的输出。判死是第二段里 [Test-RunnerCrashed] 干的活。
function Get-SuspectFiles([string]$Text, [string]$Root) {
  $map = [ordered]@{}
  foreach ($raw in ($Text -split "`r?`n")) {
    if ($raw -match 'Connection closed before test suite loaded') {
      if ($raw -match 'Failed to load "(\S*?_test\.dart)"') {
        $map[(ConvertTo-RelPath $Matches[1] $Root)] = 'KILLED'
      }
      continue
    }
    if ($raw -match 'did not complete') {
      if ($raw -match '(\S*?_test\.dart)') {
        $map[(ConvertTo-RelPath $Matches[1] $Root)] = 'KILLED'
      }
      continue
    }
    if ($raw -match '\[E\]') {
      if ($raw -match '(\S*?_test\.dart)') {
        $rel = ConvertTo-RelPath $Matches[1] $Root
        if (-not $map.Contains($rel)) { $map[$rel] = 'FAILED' }
      }
      continue
    }
    if ($raw -match 'Failed to load "(\S*?_test\.dart)"') {
      $rel = ConvertTo-RelPath $Matches[1] $Root
      if (-not $map.Contains($rel)) { $map[$rel] = 'FAILED' }
    }
  }
  return $map
}

# 输出里出现过的测试文件。用来找「一次都没轮到跑」的文件:整套跑被中途打断时,有些
# 文件既没有失败行也没有 did not complete —— 它们只是没跑到,不该被当成绿的。
function Get-MentionedFiles([string]$Text, [string]$Root) {
  $set = [ordered]@{}
  foreach ($m in [regex]::Matches($Text, '\S*?_test\.dart')) {
    $set[(ConvertTo-RelPath $m.Value $Root)] = $true
  }
  return $set
}

# 失败了要看得见原因:优先打带标记的那几行,没有标记才退回末两行。
function Show-Failure($Log) {
  $marked = @($Log | ForEach-Object { "$_" } | Where-Object {
      $_ -match 'Expected:|Actual:|TestFailure|EXCEPTION CAUGHT|Unhandled exception|Failed to load|\[E\]'
    })
  if ($marked.Count -gt 0) {
    $marked | Select-Object -First 4 | ForEach-Object { Write-Output "    $_" }
  } else {
    $Log | Select-Object -Last 2 | ForEach-Object { Write-Output "    $_" }
  }
}

# 从测试文件里抓字面量用例名 —— 拆文件时要用(见 [Invoke-PerCase])。
#
# **抓不全就返回 $null,宁可不拆**:拆错的后果是漏跑用例,那比跑红更糟。
function Get-TestNames([string]$Rel, [string]$Root) {
  $full = Join-Path $Root ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path $full)) { return $null }
  $raw = Get-Content $full -Raw
  $calls = ([regex]::Matches($raw, "(?<![\w.])(testWidgets|test)\(")).Count
  $names = @()
  foreach ($m in [regex]::Matches($raw, "(?<![\w.])(?:testWidgets|test)\(\s*'([^']+)'")) {
    $names += $m.Groups[1].Value
  }
  # 调用点数量和抓到的字面量名字数量对不上(名字是变量拼的),或者名字里带 Dart 插值
  # (比如 '第 $i 条' 这种)—— 都算抓不全。
  if ($calls -eq 0 -or $names.Count -ne $calls) { return $null }
  foreach ($n in $names) {
    if ($n.Contains('$')) { return $null }
  }
  return $names
}

# 整文件怎么跑都被杀时,把它拆成一条一条用例跑。
#
# 为什么这么拆:被杀的概率是按「这个进程渲染了多少」堆出来的 —— 实测单条 widget 用例
# 约 1%~8%,而设置页/历史页那几个文件十几条全是重渲染的用例,整个文件连着被杀 4~6 次
# (widget_settings_test 实测 6 次全崩,而同期的普通文件 6 次里崩 0~1 次)。拆开以后每个
# 进程只渲染一条用例,概率掉回单条那一档,每条再给几次机会就基本必绿。
#
# 只在「整文件反复被杀」时才走这条路:慢(一个文件几十秒),但平时一分钱不花。
function Invoke-PerCase([string]$Rel, [string]$Root, [int]$Retry) {
  $names = Get-TestNames $Rel $Root
  if ($null -eq $names) {
    return @{ verdict = 'CRASH'; detail = '用例名抓不全(不是清一色字面量),不敢拆' }
  }
  foreach ($n in $names) {
    $verdict = ''
    $log = $null
    for ($attempt = 0; $attempt -le $Retry; $attempt++) {
      Push-Location $Root
      try {
        $log = & flutter test $Rel --plain-name $n --reporter compact 2>&1
        $code = $LASTEXITCODE
      } finally {
        Pop-Location
      }
      $text = $log -join [Environment]::NewLine
      if ($text -match 'did not complete' -or $text -match 'Connection closed before test suite loaded') {
        # 进程被杀 —— 换一次机会。
        $verdict = 'CRASH'
      } elseif ($code -eq 0) {
        $verdict = 'PASS'
      } elseif ($text -match 'No tests were found') {
        # --plain-name 跑不出任何用例:名字对不上,这条根本没验到 —— 不能算绿。
        return @{ verdict = 'FAIL'; detail = "拆开后 --plain-name 跑不出「$n」(报 No tests were found)"; log = $log }
      } elseif (Test-RunnerCrashed $text) {
        $verdict = 'CRASH'
      } else {
        $verdict = 'FAIL'
      }
      if ($verdict -eq 'PASS' -or $verdict -eq 'FAIL') { break }
      Start-Sleep -Seconds $PauseSeconds
    }
    if ($verdict -eq 'FAIL') { return @{ verdict = 'FAIL'; detail = "拆开后「$n」真失败"; log = $log } }
    if ($verdict -eq 'CRASH') { return @{ verdict = 'CRASH'; detail = "拆开后「$n」跑了 $($Retry + 1) 次还是被杀"; log = $log } }
  }
  return @{ verdict = 'PASS'; detail = "拆成 $($names.Count) 条跑,全绿" }
}

# 判据自检:把各种输出形状喂进去,看分类对不对。要这个的原因很实在 —— 判据第一版
# 就是错的(要求"有 did not complete"),而它错的时候一切照旧绿:崩了的那次被当成真
# 失败上报,只有自检会为此报警。形状按实测的真实输出写,不是编的。
#
# 三组用例。第一组是真实输出形状(判据);第二组把失败标记**逐条单独**喂一遍 —— 第二组
# 才是牙齿:光有第一组的话,用例里往往同时命中多个标记,从表里删掉一条根本不会红(实测
# 删 Expected: 时全 OK)。第三组喂整套跑的原文,看挑出来的嫌疑文件对不对 —— 第一段整套
# 跑快是快,但它决定第二段重跑谁,挑漏一个文件就等于把那个文件判成了绿的。
if ($SelfCheck) {
  $shapes = @(
    @{ name = '崩了/did not complete(且带 [E])'; text = "loading test/x_test.dart`n00:03 +20 -1: x - did not complete [E]"; crashed = $true }
    @{ name = '崩了/只剩一行 loading';            text = 'loading test/x_test.dart'; crashed = $true }
    @{ name = '崩了/非零退出无输出';              text = ''; crashed = $true }
    @{ name = '崩了/加载期被杀(全量跑的原文,含 [E] 和 Failed to load)'; text = "00:00 +0 -1: loading x_test.dart [E]`n  Failed to load `"x_test.dart`": Connection closed before test suite loaded."; crashed = $true }
    @{ name = '边界/光有汇总行(刻意按崩了算)';    text = '00:02 +5 -2: Some tests failed.'; crashed = $true }
    @{ name = '真失败/断言(全量跑的原文)';        text = "00:00 +0 -1: 故意失败 [E]`n  Expected: <2>`n    Actual: <1>"; crashed = $false }
    @{ name = '真失败/编译错误(也是 Failed to load)'; text = "Failed to load `"x_test.dart`": Error: 意外的 token<EOF>"; crashed = $false }
  )
  # 这份清单是**独立写下的**:它不跟函数里的正则共用变量 —— 共用的话,删掉正则里的一条
  # 等于同时删掉它的用例,自检就永远绿了。
  $markers = @('Expected:', 'Actual:', 'TestFailure', 'EXCEPTION CAUGHT',
    'Unhandled exception', 'Failed to load', '[E]')
  # 第三组的原文是从本机跑出来的日志里抄的(2026-10-06),不是编的形状。
  $parseCases = @(
    @{
      name   = '第一段/整套被杀:did not complete + 末尾 Failing tests 两处都要认出来'
      root   = 'D:/work/repo'
      text   = @'
01:08 +463: D:/work/repo/test/widget_update_test.dart: 检查更新 点更新:先弹下载进度窗口,再把包交给系统安装器
01:13 +465: D:/work/repo/test/widget_history_test.dart: 解析页:接口没给音频,就只呈现视频卡,不拿视频顶一张音频出来 - did not complete [E]
01:13 +465: D:/work/repo/test/widget_test.dart: 横滑切板块 解析往左滑到历史,再往左到设置;到头了就不动 - did not complete [E]
01:13 +465: Some tests failed.

Failing tests:
  D:/work/repo/test/widget_history_test.dart: 冷启动预热一次连接,点输入框不会重复打 (did not complete)
'@
      expect = @{ 'test/widget_update_test.dart' = 'NONE'; 'test/widget_history_test.dart' = 'KILLED'; 'test/widget_test.dart' = 'KILLED' }
    }
    @{
      name   = '第一段/加载期被杀:Failed to load + Connection closed'
      root   = 'D:/work/repo'
      text   = @'
00:08 +115: D:/work/repo/test/media_date_test.dart: JPEG: 没有 EXIF 时不改动文件
00:08 +116 -1: loading D:/work/repo/test/downloader_native_test.dart [E]
  Failed to load "D:/work/repo/test/downloader_native_test.dart": Connection closed before test suite loaded.
'@
      expect = @{ 'test/media_date_test.dart' = 'NONE'; 'test/downloader_native_test.dart' = 'KILLED' }
    }
    @{
      name   = '第一段/真失败:带 [E] 的失败行算 FAILED,同文件先被打成 KILLED 就不再降级'
      root   = 'D:/work/repo'
      text   = @'
00:02 +3: D:/work/repo/test/foo_test.dart: 再过一条
00:02 +3 -1: D:/work/repo/test/foo_test.dart: 故意失败 [E]
  Expected: <2>
    Actual: <1>
00:02 +3 -1: D:/work/repo/test/bar_test.dart: 被杀的那条 - did not complete [E]
'@
      expect = @{ 'test/foo_test.dart' = 'FAILED'; 'test/bar_test.dart' = 'KILLED' }
    }
    @{
      name   = '第一段/全绿'
      root   = 'D:/work/repo'
      text   = @'
00:24 +450: D:/work/repo/test/widget_test.dart: 桌面端:设置页没有「检查更新」,视频路径是 Windows 的 Videos/
00:24 +450: All tests passed!
'@
      expect = @{}
    }
    @{
      name   = '第一段/相对路径也要认(逐文件跑时 flutter 也可能打相对路径)'
      root   = 'D:/work/repo'
      text   = '00:05 +2: test/audio_tags_test.dart: embedAudioTags M4A 端到端 - did not complete [E]'
      expect = @{ 'test/audio_tags_test.dart' = 'KILLED' }
    }
  )
  $bad = 0
  Write-Output "判据自检:$($shapes.Count + $markers.Count) 条"
  foreach ($c in $shapes) {
    $got = Test-RunnerCrashed $c.text
    if ($got -eq $c.crashed) {
      Write-Output "  OK   $($c.name)"
    } else {
      Write-Output "  BAD  $($c.name) —— 期望 $(if ($c.crashed) { '可重跑' } else { '不重跑' }),实得 $(if ($got) { '可重跑' } else { '不重跑' })"
      $bad++
    }
  }
  foreach ($m in $markers) {
    if (Test-RunnerCrashed $m) {
      Write-Output "  BAD  标记/$m 没被认成真失败(标记表里漏了或写错了?)"
      $bad++
    } else {
      Write-Output "  OK   标记/$m"
    }
  }
  Write-Output "输出解析自检:$($parseCases.Count) 条"
  foreach ($c in $parseCases) {
    $got = Get-SuspectFiles $c.text $c.root
    # NONE 是「明确不该被挑出来」的对照项,不参与数量比对 —— 挑多挑少都要红。
    $wantCount = @($c.expect.Keys | Where-Object { $c.expect[$_] -ne 'NONE' }).Count
    $ok = (@($got.Keys).Count -eq $wantCount)
    if ($ok) {
      foreach ($k in $c.expect.Keys) {
        $want = $c.expect[$k]
        if ($want -eq 'NONE') {
          if ($got.Contains($k)) { $ok = $false; Write-Output "        $k 不该被挑出来" }
        } elseif (-not $got.Contains($k) -or $got[$k] -ne $want) {
          $ok = $false
          Write-Output "        $k 期望 $want,实得 $(if ($got.Contains($k)) { $got[$k] } else { '没挑出来' })"
        }
      }
    }
    if ($ok) {
      Write-Output "  OK   $($c.name)"
    } else {
      $bad++
      Write-Output "  BAD  $($c.name) —— 挑出来的是:$((@($got.Keys) | ForEach-Object { "$_=$($got[$_])" }) -join ', ')"
    }
  }

  # 抓用例名:清一色字面量才敢拆 —— 掺了拼出来的名字,拆了就会漏跑用例,那比跑红更糟。
  $tmp = Join-Path ([IO.Path]::GetTempPath()) 'jicun_selftest'
  New-Item -ItemType Directory -Force $tmp | Out-Null
  Set-Content (Join-Path $tmp 'ok_test.dart') "void main() {`n  test('甲', () {});`n  testWidgets('乙', (t) async {});`n  test('丙', () {});`n}" -Encoding utf8
  Set-Content (Join-Path $tmp 'mix_test.dart') "void main() {`n  test('甲', () {});`n  for (var i = 0; i < 2; i++) { test('第 `$i 条', () {}); }`n}" -Encoding utf8
  $nameCases = @(
    @{ name = '用例名/清一色字面量(能拆)'; file = 'ok_test.dart'; expect = 3 }
    @{ name = '用例名/掺了拼出来的名字(不拆)'; file = 'mix_test.dart'; expect = -1 }
  )
  Write-Output "用例名自检:$($nameCases.Count) 条"
  foreach ($c in $nameCases) {
    $got = Get-TestNames $c.file $tmp
    $ok = if ($c.expect -eq -1) { $null -eq $got } else { $null -ne $got -and $got.Count -eq $c.expect }
    if ($ok) {
      Write-Output "  OK   $($c.name)"
    } else {
      $bad++
      Write-Output "  BAD  $($c.name) —— 期望 $(if ($c.expect -eq -1) { '不拆' } else { "$($c.expect) 个名字" }),实得 $(if ($null -eq $got) { '不拆' } else { "$($got.Count) 个名字:$($got -join '/')" })"
    }
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($bad -gt 0) {
    Write-Output "自检失败:$bad 条不符。"
    exit 1
  }
  Write-Output '判据与解析都和预期一致。'
  exit 0
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem (Join-Path $root $Path) -Recurse -Filter '*_test.dart' |
  Sort-Object FullName
$allRel = @($files | ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') })

if ($allRel.Count -eq 0) {
  Write-Output "$Path 底下没找到 *_test.dart。"
  exit 2
}
if ($Coverage -and $PerFile) {
  Write-Output '-Coverage 跟 -PerFile 不能一起用:逐文件跑覆盖率只留最后一个文件的那份。'
  exit 2
}

# 单独跑一个文件。第二段和 -PerFile 都走这里。
function Invoke-OneFile([string]$Rel) {
  Push-Location $root
  try {
    $log = & flutter test $Rel 2>&1
    $code = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  return @{ code = $code; text = ($log -join [Environment]::NewLine); log = $log }
}

$failed = New-Object System.Collections.Generic.List[string]
$recovered = New-Object System.Collections.Generic.List[string]
$stubborn = New-Object System.Collections.Generic.List[string]

# ── -PerFile:一个文件一个文件跑(爆炸半径最小,慢几倍) ──
if ($PerFile) {
  foreach ($rel in $allRel) {
    $ok = $false
    $lastR = $null
    for ($attempt = 0; $attempt -le $Retry; $attempt++) {
      if ($attempt -gt 0) {
        Write-Output "重跑 $rel ..."
        $recovered.Add($rel)
        Start-Sleep -Seconds $PauseSeconds
      }
      $r = Invoke-OneFile $rel
      $lastR = $r
      if ($VerbosePreference -eq 'Continue') {
        $r.log | ForEach-Object { Write-Output $_ }
      } else {
        $r.log | Select-Object -Last 2 | ForEach-Object { Write-Output "    $_" }
      }
      if ($r.code -eq 0) {
        $ok = $true
        break
      }
      if (-not (Test-RunnerCrashed $r.text)) {
        # 真失败:重跑只会掩盖它,直接判 FAIL。
        Write-Output '    (断言/异常失败,不重跑)'
        break
      }
    }
    if (-not $ok -and $lastR -and (Test-RunnerCrashed $lastR.text)) {
      # 整文件反复被杀 → 拆成单条用例再试一遍(见 [Invoke-PerCase])。
      $split = Invoke-PerCase $rel $root $Retry
      Write-Output "    拆开跑:$($split.detail)"
      if ($split.verdict -eq 'PASS') {
        $ok = $true
        $recovered.Add($rel)
      } elseif ($split.verdict -eq 'FAIL') {
        Show-Failure $split.log
      }
    }
    if ($ok) {
      Write-Output "PASS $rel"
    } else {
      Write-Output "FAIL $rel"
      $failed.Add($rel)
    }
  }

  ""
  "共 $($allRel.Count) 个测试文件;重跑过 $($recovered.Count) 次;失败 $($failed.Count) 个。"
  if ($failed.Count -gt 0) {
    $failed | ForEach-Object { "  失败: $_" }
    exit 1
  }
  "全部通过。"
  exit 0
}

# ── 第一段:整套跑一遍(和平时敲的那条命令一样) ──
$cli = @('test', $Path, '--reporter', 'compact')
if ($Concurrency -gt 0) { $cli += "--concurrency=$Concurrency" }
if ($Coverage) { $cli += '--coverage' }
Push-Location $root
try {
  $firstLog = & flutter test @cli 2>&1
  $firstCode = $LASTEXITCODE
} finally {
  Pop-Location
}
$firstText = $firstLog -join [Environment]::NewLine
Write-Output "第一段:整套跑一遍(flutter $($cli -join ' ')),退出码 $firstCode。"
if ($VerbosePreference -eq 'Continue') {
  $firstLog | ForEach-Object { Write-Output "    $_" }
} else {
  $firstLog | Select-Object -Last 2 | ForEach-Object { Write-Output "    $_" }
}

$suspects = Get-SuspectFiles $firstText $root
$mentioned = Get-MentionedFiles $firstText $root
foreach ($rel in $allRel) {
  if (-not $mentioned.Contains($rel) -and -not $suspects.Contains($rel)) {
    # 整套跑被中途打断时,有些文件只是没轮到 —— 不能当绿。
    $suspects[$rel] = 'UNRUN'
  }
}

$reasonText = @{ KILLED = '被杀'; FAILED = '失败'; UNRUN = '没跑到' }

if ($suspects.Count -eq 0) {
  if ($firstCode -ne 0) {
    # 整套是先跑绿、再绿的,这里说明退出码不是零却连一个文件都定位不到 —— 不能当绿放过。
    Write-Output '第一段整套失败,但输出里定位不到具体文件(见上面两行)。'
    exit 1
  }
  ""
  "共 $($allRel.Count) 个测试文件;整套一遍全绿。"
  "全部通过。"
  exit 0
}

Write-Output "挂了嫌疑的有 $($suspects.Count) 个(每个最多跑 $($Retry + 1) 次),单独重跑:"
foreach ($rel in @($suspects.Keys)) {
  $reason = $suspects[$rel]
  $verdict = ''
  $attempts = 0
  $r = $null
  for ($attempt = 0; $attempt -le $Retry; $attempt++) {
    $attempts = $attempt + 1
    if ($attempt -gt 0) {
      Write-Output "    重跑 $rel(第 $attempts 次)..."
      Start-Sleep -Seconds $PauseSeconds
    }
    $r = Invoke-OneFile $rel
    if ($VerbosePreference -eq 'Continue') {
      $r.log | ForEach-Object { Write-Output "    $_" }
    } elseif ($attempt -gt 0) {
      $r.log | Select-Object -Last 2 | ForEach-Object { Write-Output "    $_" }
    }
    if ($r.code -eq 0) { $verdict = 'PASS'; break }
    if (-not (Test-RunnerCrashed $r.text)) { $verdict = 'FAIL'; break }
    $verdict = 'CRASH'
  }
  switch ($verdict) {
    'PASS' {
      if ($attempts -gt 1) {
        Write-Output "PASS $rel(第一段$($reasonText[$reason]),第 $attempts 次绿)"
        $recovered.Add($rel)
      } else {
        Write-Output "PASS $rel(第一段$($reasonText[$reason]),自己跑是绿的)"
      }
    }
    'FAIL' {
      Write-Output "FAIL $rel(真失败,不重跑)"
      Show-Failure $r.log
      $failed.Add($rel)
    }
    default {
      # 整文件跑了 $attempts 次都是被杀 → 拆成单条用例再跑一遍(见 [Invoke-PerCase])。
      $split = Invoke-PerCase $rel $root $Retry
      if ($split.verdict -eq 'PASS') {
        Write-Output "PASS $rel(第一段$($reasonText[$reason]);整文件连崩 $attempts 次,$($split.detail))"
        $recovered.Add($rel)
      } elseif ($split.verdict -eq 'FAIL') {
        Write-Output "FAIL $rel($($split.detail);真失败,不重跑)"
        Show-Failure $split.log
        $failed.Add($rel)
      } else {
        Write-Output "FAIL $rel(整文件跑了 $attempts 次都是被杀;$($split.detail))"
        $stubborn.Add($rel)
        $failed.Add($rel)
      }
    }
  }
}

""
"共 $($allRel.Count) 个测试文件;第一段整套退出码 $firstCode;重跑后转绿的 $($recovered.Count) 个;失败 $($failed.Count) 个。"
if ($stubborn.Count -gt 0) {
  "  反复被杀(tester 崩溃,跑不出结论):"
  $stubborn | ForEach-Object { "    $_" }
  "  (崩溃是成阵的:过几分钟单独重跑这几个通常就绿 —— flutter test <文件>)"
}
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { "  失败: $_" }
  exit 1
}
"全部通过。"
