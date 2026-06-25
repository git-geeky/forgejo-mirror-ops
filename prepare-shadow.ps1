param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

$targetRoot = Join-Path $PSScriptRoot 'shadow'
$dataDir = Join-Path $targetRoot 'data'
$repoDir = Join-Path $targetRoot 'repos'
$logDir = Join-Path $targetRoot 'log'

New-Item -ItemType Directory -Path $dataDir, $repoDir, $logDir -Force | Out-Null

$sourceDb = Join-Path $SourceRoot 'data\forgejo-mirror.db'
$targetDb = Join-Path $dataDir 'forgejo-mirror.db'
if (-not (Test-Path -LiteralPath $sourceDb)) {
    throw "Missing source DB: $sourceDb"
}

sqlite3 $sourceDb ".backup '$targetDb'"
if ($LASTEXITCODE -ne 0) {
    throw "sqlite backup failed with exit $LASTEXITCODE"
}

robocopy (Join-Path $SourceRoot 'repos') $repoDir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    throw "robocopy repos failed with exit $rc"
}

$sourceIni = Join-Path $SourceRoot 'custom\conf\app.ini'
$ini = Get-Content -LiteralPath $sourceIni -Raw
$ini = $ini -replace '(?m)^HTTP_ADDR\s*=.*$', 'HTTP_ADDR = 0.0.0.0'
$ini = $ini -replace '(?m)^HTTP_PORT\s*=.*$', 'HTTP_PORT = 3000'
$ini = $ini -replace '(?m)^WORK_PATH\s*=.*$', 'WORK_PATH = /var/lib/gitea'
$ini = $ini -replace '(?m)^PATH\s*=.*$', 'PATH = /var/lib/gitea/forgejo-mirror.db'
$ini = $ini -replace '(?m)^ROOT\s*=.*$', 'ROOT = /var/lib/gitea/git/repositories'
if ($ini -notmatch '(?m)^APP_DATA_PATH\s*=') {
    $ini = $ini -replace '(?m)^RUN_MODE\s*=.*$', ('$0' + [Environment]::NewLine + 'APP_DATA_PATH = /var/lib/gitea')
} else {
    $ini = $ini -replace '(?m)^APP_DATA_PATH\s*=.*$', 'APP_DATA_PATH = /var/lib/gitea'
}
[System.IO.File]::WriteAllText((Join-Path $targetRoot 'app.ini'), $ini, [System.Text.UTF8Encoding]::new($false))

Write-Output "Prepared Forgejo mirror shadow data at $targetRoot"
