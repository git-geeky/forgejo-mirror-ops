param(
    [string]$MirrorRoot = (Join-Path $PSScriptRoot 'shadow\repos\mirror-admin'),
    [string]$StateRoot = 'C:\ProgramData\ForgejoMirror',
    [Parameter(Mandatory = $true)]
    [string]$RemoteRepoRoot,
    [string]$RemoteTarget = $(if ($env:FORGEJO_REMOTE_TARGET) { $env:FORGEJO_REMOTE_TARGET } else { 'aiserver' }),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-LocalRefSignatures {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Local mirror root not found: $Root"
    }

    $result = @{}
    Get-ChildItem -LiteralPath $Root -Directory -Filter '*.git' | Sort-Object Name | ForEach-Object {
        $refs = & git --git-dir $_.FullName show-ref --head 2>$null
        if ($LASTEXITCODE -ne 0) {
            $refs = @()
        }

        $refsSorted = @($refs | Sort-Object)
        $result[$_.Name] = if ($refsSorted.Count -eq 0) {
            'EMPTY'
        }
        else {
            Get-Sha256Hex ($refsSorted -join "`n")
        }
    }

    return $result
}

. "$env:USERPROFILE\bin\codex-ssh-tools.ps1"

$logDir = Join-Path $StateRoot 'logs'
$stateFile = Join-Path $StateRoot 'sync-state.txt'
$auditLog = Join-Path $logDir 'integrity-check.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$local = Get-LocalRefSignatures -Root $MirrorRoot

$remoteScript = @'
set -euo pipefail
root='__REMOTE_REPO_ROOT__'
sudo find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.git' | sort | while read -r repo; do
  name="$(basename "$repo")"
  refs="$(sudo git --git-dir="$repo" show-ref --head 2>/dev/null | sort || true)"
  if [ -z "$refs" ]; then
    sig="EMPTY"
  else
    sig="$(printf '%s' "$refs" | sha256sum | awk '{print $1}')"
  fi
  printf '%s|%s\n' "$name" "$sig"
done
'@
$remoteScript = $remoteScript.Replace('__REMOTE_REPO_ROOT__', $RemoteRepoRoot.Replace("'", "'\''"))

$remoteText = Invoke-RemoteBash -Target $RemoteTarget -Script $remoteScript

$remote = @{}
($remoteText -split "`r?`n" | Where-Object { $_ -match '^[^|]+\|(EMPTY|[0-9a-f]{64})$' }) | ForEach-Object {
    $parts = $_ -split '\|', 2
    $remote[$parts[0]] = $parts[1]
}

$missing = @($remote.Keys | Where-Object { -not $local.ContainsKey($_) } | Sort-Object)
$extra = @($local.Keys | Where-Object { -not $remote.ContainsKey($_) } | Sort-Object)
$mismatch = @($remote.Keys | Where-Object { $local.ContainsKey($_) -and $local[$_] -ne $remote[$_] } | Sort-Object)

$status = if (($missing.Count + $extra.Count + $mismatch.Count) -eq 0) { 'OK' } else { 'DRIFT' }
$now = Get-Date
$summary = [ordered]@{
    timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ssK')
    status = $status
    remote_count = $remote.Keys.Count
    mirror_count = $local.Keys.Count
    missing_count = $missing.Count
    extra_count = $extra.Count
    mismatch_count = $mismatch.Count
    missing = $missing
    extra = $extra
    mismatch = $mismatch
}

$line = '{0} REMOTE={1} MIRROR={2} MISSING={3} EXTRA={4} MISMATCH={5} {6}' -f `
    $summary.timestamp, $summary.remote_count, $summary.mirror_count, `
    $summary.missing_count, $summary.extra_count, $summary.mismatch_count, $summary.status
Add-Content -LiteralPath $auditLog -Value $line
$status | Set-Content -LiteralPath $stateFile -Encoding ascii

if ($status -ne 'OK') {
    $driftFile = Join-Path $logDir ("drift-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $driftFile -Encoding utf8
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 4
}
else {
    $line
    if ($status -ne 'OK') {
        if ($missing.Count) { "MISSING: $($missing -join ', ')" }
        if ($extra.Count) { "EXTRA: $($extra -join ', ')" }
        if ($mismatch.Count) { "MISMATCH: $($mismatch -join ', ')" }
    }
}

if ($status -ne 'OK') {
    exit 1
}
