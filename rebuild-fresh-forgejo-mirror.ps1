param(
    [Parameter(Mandatory = $true)]
    [string]$RemoteUrl,
    [string]$RemoteCloneBase = $(if ($env:FORGEJO_REMOTE_CLONE_BASE) { $env:FORGEJO_REMOTE_CLONE_BASE } else { '' }),
    [string]$MirrorDomain = $(if ($env:FORGEJO_MIRROR_DOMAIN) { $env:FORGEJO_MIRROR_DOMAIN } else { 'localhost' }),
    [string]$RootUrl = $(if ($env:FORGEJO_MIRROR_ROOT_URL) { $env:FORGEJO_MIRROR_ROOT_URL } else { 'http://127.0.0.1:3300/' }),
    [string]$LocalOwner = $(if ($env:FORGEJO_MIRROR_LOCAL_OWNER) { $env:FORGEJO_MIRROR_LOCAL_OWNER } else { 'mirror-admin' })
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-credential.ps1')

$image = 'codeberg.org/forgejo/forgejo:15.0.3-rootless'
$shadow = Join-Path $PSScriptRoot 'shadow'
$backupRoot = Join-Path $PSScriptRoot 'backups'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $backupRoot "pre-fresh-forgejo-$timestamp"
$repoLinuxPath = (& wsl -d Ubuntu -- wslpath -a $PSScriptRoot).Trim()

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

Write-Output "Stopping old local mirror containers..."
wsl -d Ubuntu -- bash -lc "cd '$repoLinuxPath' && docker compose -f docker-compose.prod.yml down >/dev/null 2>&1 || true; docker rm -f local-gitea-mirror local-forgejo-mirror >/dev/null 2>&1 || true"

if (Test-Path -LiteralPath $shadow) {
    Write-Output "Backing up old mirror shadow to $backup"
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    robocopy $shadow (Join-Path $backup 'shadow') /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy backup failed with exit $LASTEXITCODE"
    }
}

Remove-Item -LiteralPath $shadow -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path `
    (Join-Path $shadow 'data'), `
    (Join-Path $shadow 'repos'), `
    (Join-Path $shadow 'log') -Force | Out-Null

Write-Output "Generating Forgejo secrets..."
function New-Base64UrlSecret([int]$Bytes = 48) {
    $bytesValue = [byte[]]::new($Bytes)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytesValue)
    }
    finally {
        $rng.Dispose()
    }
    [Convert]::ToBase64String($bytesValue).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$internalToken = New-Base64UrlSecret 64
$secretKey = New-Base64UrlSecret 48
$jwtSecret = New-Base64UrlSecret 48
if (-not $internalToken -or -not $secretKey -or -not $jwtSecret) {
    throw 'secret generation failed'
}

$appIni = @"
APP_NAME = Forgejo Mirror
RUN_MODE = prod
APP_DATA_PATH = /var/lib/gitea
WORK_PATH = /var/lib/gitea

[server]
DOMAIN = $MirrorDomain
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
ROOT_URL = $RootUrl
OFFLINE_MODE = true
START_SSH_SERVER = false
DISABLE_SSH = true
LFS_START_SERVER = false

[database]
DB_TYPE = sqlite3
PATH = /var/lib/gitea/forgejo-mirror.db

[repository]
ROOT = /var/lib/gitea/git/repositories

[service]
DISABLE_REGISTRATION = true

[mirror]
DEFAULT_INTERVAL = 1h
MIN_INTERVAL = 15m

[security]
INSTALL_LOCK = true
INTERNAL_TOKEN = $internalToken
SECRET_KEY = $secretKey

[log]
ROOT_PATH = /var/lib/gitea/log
MODE = file
LEVEL = Info

[cron.update_mirrors]
SCHEDULE = @every 1h

[oauth2]
JWT_SECRET = $jwtSecret
"@

[IO.File]::WriteAllText((Join-Path $shadow 'app.ini'), $appIni, [Text.UTF8Encoding]::new($false))

Write-Output "Starting local Forgejo mirror..."
wsl -d Ubuntu -- bash -lc "cd '$repoLinuxPath' && docker compose -f docker-compose.prod.yml pull && docker compose -f docker-compose.prod.yml up -d"

$deadline = (Get-Date).AddSeconds(90)
do {
    Start-Sleep -Seconds 2
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3300/' -TimeoutSec 5
        if ($response.StatusCode -eq 200) { break }
    } catch {
        $response = $null
    }
} while ((Get-Date) -lt $deadline)
if (-not $response -or $response.StatusCode -ne 200) {
    wsl -d Ubuntu -- bash -lc 'docker logs --tail 120 local-forgejo-mirror 2>&1' | Write-Output
    throw 'local Forgejo mirror did not become ready'
}

Write-Output "Creating local admin and API token..."
$adminPassword = New-Base64UrlSecret 36
$localOwner = $LocalOwner
$adminEmail = $localOwner + '@' + 'example.invalid'
$createScript = @"
docker exec local-forgejo-mirror forgejo admin user create --config /etc/gitea/app.ini --username $localOwner --password '$adminPassword' --email $adminEmail --admin --must-change-password=false >/tmp/create-admin.out 2>/tmp/create-admin.err
cat /tmp/create-admin.err >&2
rm -f /tmp/create-admin.out /tmp/create-admin.err
"@
wsl -d Ubuntu -- bash -lc $createScript | Out-Null

$token = (wsl -d Ubuntu -- bash -lc "docker exec local-forgejo-mirror forgejo admin user generate-access-token --config /etc/gitea/app.ini --username $localOwner --token-name mirror-sync --scopes write:repository --raw").Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'local token generation failed'
}
Set-WindowsGenericCredentialSecret -Target 'forgejomirror-local-api' -UserName 'token' -Secret $token

Write-Output "Running mirror sync..."
& (Join-Path $PSScriptRoot 'sync-new-repos.ps1') -RemoteUrl $RemoteUrl -RemoteCloneBase $RemoteCloneBase -LocalOwner $LocalOwner

Write-Output "Fresh local Forgejo mirror rebuild completed."
Write-Output "Backup: $backup"
