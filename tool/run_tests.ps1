# 逐文件跑 flutter test,最后给出汇总。
#
# 为什么要这么跑:Windows 上的 flutter_tester.exe 有一条引擎级缺陷 ——
# `ShaderMask`(blendMode: dstIn)+ 滚动列表在软件渲染下会以 0xc0000005(访问违例,
# 偏移恒定 0x35aaf0)静默杀掉整个测试进程,一次带走同一文件里剩下的几十条用例。
# 触发是概率性的(约 0.1%/用例),和具体用例无关,只跟"这个文件跑了多少渲染"有关。
# 详见 README「测试」一节。
#
# 逐文件跑的两个好处:一个文件崩只影响它自己;崩溃那次重试一次就把概率抹掉。
#
# **只对"tester 崩了"重试**。断言/异常失败一律直接 FAIL —— 无脑重试会把"偶尔
# 挂一次"的真 bug 抹成绿色,那是拿重试当遮羞布。判据见 [Test-RunnerCrashed]。
#
# 改过判据就扫一下它:`.\tool\run_tests.ps1 -SelfCheck`(只跑自检,不跑测试)。
param(
  [int]$Retry = 1,
  [string]$Path = 'test',
  [switch]$SelfCheck
)

# 这次失败是"tester 崩了(可重试)"还是"真的失败(不许重试)"?
#
# 判据是**看有没有失败标记**,而不是看有没有 `did not complete`:后者只是崩溃的一种
# 形态。实测崩得最干脆的那次,输出只剩一行 `loading test/xxx_test.dart`,连 `[E]` 都
# 没来得及打 —— 那时按"没有 did not complete 就是真失败"会判反,把崩溃当成假失败。
#
# 反过来,真失败**一定**留标记:断言(Expected/Actual/TestFailure)、未捕获异常、
# 编译/加载失败(Failed to load)、或者报告器打的 `[E]` 失败行。两条都不沾的非零退出
# 只可能是进程没了,按崩溃算、放它重试一次。
#
# **"进程没了"有一句话专属于它,必须排在标记表前面查**:`Connection closed before
# test suite loaded.` —— 加载期就被杀时 flutter 报的是
# `Failed to load "...": Connection closed before test suite loaded.`,它同时带
# `Failed to load` 和 `[E]`,先查标记就会当成真失败 —— 全量跑时真撞上了:某个文件在
# loading 阶段被杀,判成真失败不重试,单独跑 17/17 反而全绿。断言失败和编译错误都不会
# 说 connection closed,这句话只可能是进程死了。
function Test-RunnerCrashed([string]$Text) {
  if ($Text -match 'did not complete') { return $true }
  if ($Text -match 'Connection closed before test suite loaded') { return $true }
  if ($Text -match 'Expected:|Actual:|TestFailure|EXCEPTION CAUGHT|Unhandled exception|Failed to load|\[E\]') {
    return $false
  }
  return $true
}

# 判据自检:把各种输出形状喂进去,看分类对不对。要这个的原因很实在 —— 判据第一版
# 就是错的(要求"有 did not complete"),而它错的时候一切照旧绿:崩了的那次被当成真
# 失败上报,只有自检会为此报警。形状按实测的真实输出写,不是编的。
#
# 两组用例。第一组是真实输出形状;第二组把失败标记**逐条单独**喂一遍 —— 第二组才是
# 牙齿:光有第一组的话,用例里往往同时命中多个标记,从表里删掉一条根本不会红(实测
# 删 Expected: 时全 OK)。
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
  $bad = 0
  Write-Output "判据自检:$($shapes.Count + $markers.Count) 条"
  foreach ($c in $shapes) {
    $got = Test-RunnerCrashed $c.text
    if ($got -eq $c.crashed) {
      Write-Output "  OK   $($c.name)"
    } else {
      Write-Output "  BAD  $($c.name) —— 期望 $(if ($c.crashed) { '可重试' } else { '不重试' }),实得 $(if ($got) { '可重试' } else { '不重试' })"
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
  if ($bad -gt 0) {
    Write-Output "判据自检失败:$bad 条不符。"
    exit 1
  }
  Write-Output '判据与预期一致。'
  exit 0
}

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem (Join-Path $root $Path) -Recurse -Filter '*_test.dart' |
  Sort-Object FullName

$failed = New-Object System.Collections.Generic.List[string]
$retried = New-Object System.Collections.Generic.List[string]

foreach ($f in $files) {
  $rel = [IO.Path]::GetRelativePath($root, $f.FullName).Replace('\', '/')
  $ok = $false
  for ($attempt = 0; $attempt -le $Retry; $attempt++) {
    if ($attempt -gt 0) {
      Write-Output "重试 $rel ..."
      $retried.Add($rel)
    }
    Push-Location $root
    try {
      # 逐文件的输出太吵:默认只留末两行(通过数 / 失败原因),-Verbose 才打全程。
      $log = & flutter test $rel 2>&1
      $code = $LASTEXITCODE
    } finally {
      Pop-Location
    }
    if ($VerbosePreference -eq 'Continue') {
      $log | ForEach-Object { Write-Output $_ }
    } else {
      $log | Select-Object -Last 2 | ForEach-Object { Write-Output "    $_" }
    }
    if ($code -eq 0) {
      $ok = $true
      break
    }
    if (-not (Test-RunnerCrashed ($log -join [Environment]::NewLine))) {
      # 真失败:重试只会掩盖它,直接判 FAIL。
      Write-Output '    (断言/异常失败,不重试)'
      break
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
"共 $($files.Count) 个测试文件;重试过 $($retried.Count) 次;失败 $($failed.Count) 个。"
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { "  失败: $_" }
  exit 1
}
"全部通过。"
