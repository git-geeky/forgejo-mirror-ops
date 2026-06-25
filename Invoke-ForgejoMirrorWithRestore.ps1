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

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
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
$scriptArgs = @()

switch ($Command) {
    'sync-new-repos' {
        $remoteUrl = Get-OptionalString $cfg 'remote_url'
        if (-not $remoteUrl) { throw "restore config missing remote_url" }
        $scriptArgs = @(
            '-RemoteUrl', $remoteUrl,
            '-LocalUrl', (Get-OptionalString $cfg 'local_url' 'http://127.0.0.1:3300/api/v1'),
            '-RemoteCloneBase', (Get-OptionalString $cfg 'remote_clone_base'),
            '-LocalOwner', (Get-OptionalString $cfg 'local_owner' 'mirror-admin'),
            '-LocalCredentialTarget', (Get-OptionalString $credentialTargets 'local_api' 'forgejomirror-local-api'),
            '-RemoteCredentialTarget', (Get-OptionalString $credentialTargets 'remote_api' 'forgejo-remote-api')
        )
        & (Join-Path $PSScriptRoot 'sync-new-repos.ps1') @scriptArgs @ExtraArgs
    }
    'test-refs' {
        $remoteRepoRoot = Get-OptionalString $cfg 'remote_repo_root'
        if (-not $remoteRepoRoot) { throw "restore config missing remote_repo_root" }
        $scriptArgs = @(
            '-RemoteRepoRoot', $remoteRepoRoot,
            '-RemoteTarget', (Get-OptionalString $cfg 'remote_target' 'aiserver')
        )
        & (Join-Path $PSScriptRoot 'Test-ForgejoMirrorRefs.ps1') @scriptArgs @ExtraArgs
    }
    'sync-drift' {
        $remoteRepoRoot = Get-OptionalString $cfg 'remote_repo_root'
        if (-not $remoteRepoRoot) { throw "restore config missing remote_repo_root" }
        $scriptArgs = @(
            '-RemoteRepoRoot', $remoteRepoRoot,
            '-RemoteTarget', (Get-OptionalString $cfg 'remote_target' 'aiserver'),
            '-RemoteHeaderBase', (Get-OptionalString $cfg 'remote_header_base'),
            '-LocalCredentialTarget', (Get-OptionalString $credentialTargets 'local_api' 'forgejomirror-local-api')
        )
        & (Join-Path $PSScriptRoot 'Sync-ForgejoMirrorDrift.ps1') @scriptArgs @ExtraArgs
    }
}
