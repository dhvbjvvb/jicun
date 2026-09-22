# Deploy the "jicun" parse reverse proxy to the server. Idempotent, safe to re-run.
#
# Steps:
#   1. bundle the site config, limits config, cfip script and deploy script from deploy/;
#   2. scp the bundle up;
#   3. unpack on the server, rename into place under /tmp, run jicun-deploy.sh with sudo;
#   4. the server output is printed here - including nginx -t, reload, and a self-test
#      of all four upstream routes.
#
# The API key never lands in this repo: pass it with -BugpkKey, and deploy-nginx.sh
# installs it on the server as /etc/nginx/jicun-secret2.conf (mode 600).
#
# Usage:
#   pwsh deploy/deploy-jicun.ps1 -Target root@1.2.3.4 -BugpkKey bp_live_xxx
#   pwsh deploy/deploy-jicun.ps1 -Target root@1.2.3.4 -BugpkKeyFile C:\key.txt
#   pwsh deploy/deploy-jicun.ps1 -Target root@1.2.3.4     # key already on the server
#
# Parameters:
#   -Target        server, optionally with user, e.g. root@1.2.3.4 (required)
#   -Port          SSH port, default 22
#   -IdentityFile  private key path (default: let ssh decide, honours ~/.ssh/config)
#   -BugpkKey      BugPk upstream bp_live key, as a string
#   -BugpkKeyFile  file holding that key (safer: keeps it out of shell history)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [int]$Port = 22,
    [string]$IdentityFile,
    [string]$BugpkKey,
    [string]$BugpkKeyFile
)

$ErrorActionPreference = 'Stop'
$deployDir = $PSScriptRoot

if ($BugpkKey -and $BugpkKeyFile) {
    throw 'give either -BugpkKey or -BugpkKeyFile, not both'
}
if ($BugpkKeyFile) {
    if (-not (Test-Path $BugpkKeyFile)) { throw "key file not found: $BugpkKeyFile" }
    $BugpkKey = (Get-Content $BugpkKeyFile -Raw).Trim()
}

# Local file name -> name under /tmp on the server. tar cannot rename members, so the
# rename happens remotely (see $steps below); deploy-nginx.sh expects the right column.
$files = [ordered]@{
    'nginx-mxper.cc.cd.conf' = 'jicun-site.conf'
    'jicun-limits.conf'      = 'jicun-limits.conf'
    'jicun-cfip.sh'          = 'jicun-cfip.sh'
    'jicun-cfip.cron'        = 'jicun-cfip.cron'
    'deploy-nginx.sh'        = 'jicun-deploy.sh'
}

foreach ($name in $files.Keys) {
    $path = Join-Path $deployDir $name
    if (-not (Test-Path $path)) { throw "missing file: $path" }
}

# One tarball instead of five scp calls: fewer round trips, and tar ships with
# Windows 10 1803+.
$tarball = Join-Path $env:TEMP 'jicun-deploy.tar.gz'
if (Test-Path $tarball) { Remove-Item $tarball -Force }

Push-Location $deployDir
try {
    & tar -czf $tarball @($files.Keys)
    if ($LASTEXITCODE -ne 0) { throw "tar failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}
$kb = [math]::Round((Get-Item $tarball).Length / 1KB, 1)
Write-Host "packed: $tarball ($kb KB)"

# BatchMode: fail fast when a password would be needed instead of hanging on a prompt.
$sshArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-p', "$Port")
# scp takes an upper-case -P for the port (-p means "preserve timestamps"), so the two
# commands cannot share one argument list.
$scpArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-P', "$Port")
if ($IdentityFile) {
    $sshArgs += @('-i', $IdentityFile)
    $scpArgs += @('-i', $IdentityFile)
}

function Invoke-Remote([string]$Command) {
    & ssh @sshArgs $Target $Command
    if ($LASTEXITCODE -ne 0) { throw "remote command failed (exit $LASTEXITCODE): $Command" }
}

Write-Host '== 1/3 upload =='
& scp @scpArgs $tarball "${Target}:/tmp/jicun-deploy.tar.gz"
if ($LASTEXITCODE -ne 0) { throw 'scp upload failed' }

# Check sudo first. With BatchMode a password prompt just errors out, and that error
# would be confusing, so say what to do instead.
Write-Host '== 2/3 check sudo =='
& ssh @sshArgs $Target 'sudo -n true'
if ($LASTEXITCODE -ne 0) {
    Write-Host 'remote sudo needs a password; this script cannot type it.' -ForegroundColor Yellow
    Write-Host 'Run as root, or give that account passwordless sudo:'
    Write-Host '  pwsh deploy/deploy-jicun.ps1 -Target root@<ip> -BugpkKey bp_live_xxx'
    throw 'sudo unavailable'
}

# The API key is staged as a file and scp'd, never interpolated into a shell command:
# quotes or semicolons in it would break that line, and it would show up in shell history.
$secretLocal = $null
if ($BugpkKey) {
    $secretLocal = Join-Path $env:TEMP 'jicun-secret2.conf'
    $line = 'proxy_set_header X-API-Key "' + $BugpkKey + '";'
    [System.IO.File]::WriteAllText($secretLocal, $line + "`n")
    Write-Host '== upload key =='
    & scp @scpArgs $secretLocal "${Target}:/tmp/jicun-secret2.conf"
    if ($LASTEXITCODE -ne 0) { throw 'scp key failed' }
    Remove-Item $secretLocal -Force
    Invoke-Remote 'chmod 600 /tmp/jicun-secret2.conf'
}

Write-Host '== 3/3 unpack + deploy =='
# tar members keep their local names, so copy each into the name deploy-nginx.sh wants.
$steps = @(
    'set -e',
    'cd /tmp',
    'rm -rf /tmp/jicun-bundle',
    'mkdir -p /tmp/jicun-bundle',
    'tar -xzf /tmp/jicun-deploy.tar.gz -C /tmp/jicun-bundle',
    'cd /tmp/jicun-bundle',
    'cp nginx-mxper.cc.cd.conf /tmp/jicun-site.conf',
    'cp jicun-limits.conf /tmp/jicun-limits.conf',
    'cp jicun-cfip.sh /tmp/jicun-cfip.sh',
    'cp jicun-cfip.cron /tmp/jicun-cfip.cron',
    'cp deploy-nginx.sh /tmp/jicun-deploy.sh',
    'chmod 755 /tmp/jicun-cfip.sh',
    'cd /tmp',
    'rm -rf /tmp/jicun-bundle',
    # cron.d files must end with a newline or cron silently ignores them.
    "printf '\n' >> /tmp/jicun-cfip.cron",
    'sudo bash /tmp/jicun-deploy.sh'
)

Invoke-Remote ($steps -join ' && ')

Write-Host ''
Write-Host '== done ==' -ForegroundColor Green
Write-Host 'If you saw RELOADED OK and all four /parse2/* probes are 200/422, this side is ready.'
Write-Host 'Manual check:'
Write-Host "  curl -s 'https://mxper.cc.cd/parse2/dy?url=<douyin share link>' | head -c 200"
