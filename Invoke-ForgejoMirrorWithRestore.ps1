[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sync-new-repos', 'test-refs', 'sync-drift')]
    [string]$Command,

    [string]$RestoreConfig = $(if ($env:FORGEJO_MIRROR_RESTORE_FILE) {
        $env:FORGEJO_MIRROR_RESTORE_FILE
    } elseif ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'forgejo-mirror-ops\restore.local.json'
    } else {
        Join-Path $HOME '.config\forgejo-mirror-ops\restore.local.json'
    }),

    [switch]$Json,

    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

function Get-OptionalString($Object, [string]$Name, [string]$Default = '') {
    if ($null -ne $Object.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        return [string]$Object.$Name
    }
    return $Default
}

if (-not (Test-Path -LiteralPath $RestoreConfig)) {
    throw "Restore config not found. Copy config\restore.example.json outside the repo and set FORGEJO_MIRROR_RESTORE_FILE."
}

$cfg = Get-Content -Raw -LiteralPath $RestoreConfig | ConvertFrom-Json
$credentialTargets = if ($null -ne $cfg.credential_targets) { $cfg.credential_targets } else { [pscustomobject]@{} }
$ExtraArgs = @($ExtraArgs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$scriptArgs = @{}

switch ($Command) {
    'sync-new-repos' {
        $remoteUrl = Get-OptionalString $cfg 'remote_url'
        if (-not $remoteUrl) { throw "restore config missing remote_url" }
        $scriptArgs = @{
            RemoteUrl = $remoteUrl
            LocalUrl = Get-OptionalString $cfg 'local_url' 'http://127.0.0.1:3300/api/v1'
            RemoteCloneBase = Get-OptionalString $cfg 'remote_clone_base'
            LocalOwner = Get-OptionalString $cfg 'local_owner' 'mirror-admin'
            MirrorRoot = Get-OptionalString $cfg 'mirror_shadow_root' (Join-Path $PSScriptRoot 'shadow')
            LocalCredentialTarget = Get-OptionalString $credentialTargets 'local_api' 'forgejomirror-local-api'
            RemoteCredentialTarget = Get-OptionalString $credentialTargets 'remote_api' 'forgejo-remote-api'
        }
        & (Join-Path $PSScriptRoot 'sync-new-repos.ps1') @scriptArgs @ExtraArgs
    }
    'test-refs' {
        $remoteRepoRoot = Get-OptionalString $cfg 'remote_repo_root'
        if (-not $remoteRepoRoot) { throw "restore config missing remote_repo_root" }
        $scriptArgs = @{
            RemoteRepoRoot = $remoteRepoRoot
            RemoteTarget = Get-OptionalString $cfg 'remote_target' 'aiserver'
            MirrorRoot = Get-OptionalString $cfg 'mirror_bare_root' (Join-Path $PSScriptRoot 'shadow\repos\mirror-admin')
        }
        if ($Json) { $scriptArgs.Json = $true }
        & (Join-Path $PSScriptRoot 'Test-ForgejoMirrorRefs.ps1') @scriptArgs @ExtraArgs
    }
    'sync-drift' {
        $remoteRepoRoot = Get-OptionalString $cfg 'remote_repo_root'
        if (-not $remoteRepoRoot) { throw "restore config missing remote_repo_root" }
        $scriptArgs = @{
            RemoteRepoRoot = $remoteRepoRoot
            RemoteTarget = Get-OptionalString $cfg 'remote_target' 'aiserver'
            RemoteHeaderBase = Get-OptionalString $cfg 'remote_header_base'
            MirrorRoot = Get-OptionalString $cfg 'mirror_bare_root' (Join-Path $PSScriptRoot 'shadow\repos\mirror-admin')
            LocalCredentialTarget = Get-OptionalString $credentialTargets 'local_api' 'forgejomirror-local-api'
        }
        if ($Json) { $scriptArgs.Json = $true }
        & (Join-Path $PSScriptRoot 'Sync-ForgejoMirrorDrift.ps1') @scriptArgs @ExtraArgs
    }
}
