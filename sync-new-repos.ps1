param(
    [string]$LocalUrl = $(if ($env:FORGEJO_MIRROR_LOCAL_API) { $env:FORGEJO_MIRROR_LOCAL_API } else { 'http://127.0.0.1:3300/api/v1' }),
    [Parameter(Mandatory = $true)]
    [string]$RemoteUrl,
    [string]$RemoteCloneBase = $(if ($env:FORGEJO_REMOTE_CLONE_BASE) { $env:FORGEJO_REMOTE_CLONE_BASE } else { '' }),
    [string]$LocalOwner = $(if ($env:FORGEJO_MIRROR_LOCAL_OWNER) { $env:FORGEJO_MIRROR_LOCAL_OWNER } else { 'mirror-admin' }),
    [string]$MirrorRoot = (Join-Path $PSScriptRoot 'shadow'),
    [string]$LocalCredentialTarget = $(if ($env:FORGEJO_MIRROR_LOCAL_CREDENTIAL_TARGET) { $env:FORGEJO_MIRROR_LOCAL_CREDENTIAL_TARGET } else { 'forgejomirror-local-api' }),
    [string]$RemoteCredentialTarget = $(if ($env:FORGEJO_REMOTE_CREDENTIAL_TARGET) { $env:FORGEJO_REMOTE_CREDENTIAL_TARGET } else { 'forgejo-remote-api' })
)

# Discovers new repos on a remote Forgejo instance and creates local pull-mirrors
# for any missing ones.

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-credential.ps1')

$LocalToken = Get-WindowsGenericCredentialSecret -Target $LocalCredentialTarget
$RemoteToken = Get-WindowsGenericCredentialSecret -Target $RemoteCredentialTarget
if ([string]::IsNullOrWhiteSpace($LocalToken)) { throw "missing CredMan target '$LocalCredentialTarget'" }
if ([string]::IsNullOrWhiteSpace($RemoteToken)) { throw "missing CredMan target '$RemoteCredentialTarget'" }

$RepoRoot = Join-Path $MirrorRoot "repos\$LocalOwner"
$LogFile = Join-Path $MirrorRoot 'log\sync-new-repos.log'

New-Item -ItemType Directory -Path (Split-Path -Parent $LogFile) -Force | Out-Null

function Write-Log($msg) {
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    "$ts  $msg" | Tee-Object -FilePath $LogFile -Append
}

function Invoke-ForgejoGet($url, $headers) {
    Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 60
}

Write-Log "=== Starting new-repo discovery ==="

$headers = @{ Authorization = "token $RemoteToken" }
$remoteRepos = @()
$page = 1
do {
    $batch = (Invoke-ForgejoGet "$RemoteUrl/repos/search?limit=50&page=$page" $headers).data
    if ($batch) { $remoteRepos += $batch }
    $page++
} while ($batch -and $batch.Count -eq 50)

$localHeaders = @{ Authorization = "token $LocalToken" }
$localRepos = @()
$page = 1
do {
    $batch = (Invoke-ForgejoGet "$LocalUrl/repos/search?limit=50&page=$page" $localHeaders).data
    if ($batch) { $localRepos += $batch }
    $page++
} while ($batch -and $batch.Count -eq 50)
$localNames = $localRepos | ForEach-Object { $_.name }

$created = 0
$skipped = 0

foreach ($repo in $remoteRepos) {
    $repoName = $repo.name
    $fullName = $repo.full_name

    if ($localNames -contains $repoName) {
        $skipped++
        continue
    }

    if ($repoName -match '-archived$') {
        $skipped++
        continue
    }

    Write-Log "New repo found: $fullName - creating mirror..."

    $body = @{
        clone_addr      = $repo.clone_url
        auth_token      = $RemoteToken
        repo_name       = $repoName
        repo_owner      = $LocalOwner
        mirror          = $true
        mirror_interval = '1h'
        description     = "Mirror of $fullName from upstream Forgejo"
        private         = $repo.private
        service         = 'gitea'
    } | ConvertTo-Json

    try {
        $null = Invoke-RestMethod -Uri "$LocalUrl/repos/migrate" -Method POST `
            -Headers $localHeaders -ContentType 'application/json' -Body $body -TimeoutSec 300
        Write-Log "  Created mirror: $repoName"
        $created++

        $repoPath = Join-Path $RepoRoot "$repoName.git"
        if (Test-Path "$repoPath\config") {
            if (-not [string]::IsNullOrWhiteSpace($RemoteCloneBase)) {
                $cleanUrl = "$($RemoteCloneBase.TrimEnd('/'))/$repoName.git"
                & git --git-dir=$repoPath remote set-url origin $cleanUrl 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "  Scrubbed embedded PAT from URL"
                } else {
                    Write-Log "  WARN: URL scrub failed (exit $LASTEXITCODE) - manual cleanup needed"
                }
            }
        }
    }
    catch {
        Write-Log "  FAILED: $repoName - $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 1
}

Write-Log "Discovery complete: $created new mirrors created, $skipped already existed, $($remoteRepos.Count) remote repos inspected."
Write-Log "=== Done ==="
