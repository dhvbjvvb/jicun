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
param(
  [int]$Retry = 1,
  [string]$Path = 'test'
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
function Test-RunnerCrashed([string]$Text) {
  if ($Text -match 'did not complete') { return $true }
  if ($Text -match 'Expected:|Actual:|TestFailure|EXCEPTION CAUGHT|Unhandled exception|Failed to load|\[E\]') {
    return $false
  }
  return $true
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
