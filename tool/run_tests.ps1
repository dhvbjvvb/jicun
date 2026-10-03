# 逐文件跑 flutter test,每个文件失败重试一次,最后给出汇总。
#
# 为什么要这么跑:Windows 上的 flutter_tester.exe 有一条引擎级缺陷 ——
# `ShaderMask`(blendMode: dstIn)+ 滚动列表在软件渲染下会以 0xc0000005(访问违例,
# 偏移恒定 0x35aaf0)静默杀掉整个测试进程,一次带走同一文件里剩下的几十条用例。
# 触发是概率性的(约 0.1%/用例),和具体用例无关,只跟"这个文件跑了多少渲染"有关。
# 详见 README「测试」一节。
#
# 逐文件跑的两个好处:一个文件崩只影响它自己;重试一次就把那点概率抹掉。
param(
  [int]$Retry = 1,
  [string]$Path = 'test'
)

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
