param(
    [string]$VerifierPath = (Join-Path $PSScriptRoot 'Test-ForgejoMirrorRefs.ps1'),
    [string]$ApiBase = 'http://127.0.0.1:3300/api/v1',
    [string]$MirrorRoot = (Join-Path $PSScriptRoot 'shadow\repos\mirror-admin'),
    [string]$LocalOwner = 'mirror-admin',
    [Parameter(Mandatory = $true)]
    [string]$RemoteRepoRoot,
    [string]$RemoteTarget = $(if ($env:FORGEJO_REMOTE_TARGET) { $env:FORGEJO_REMOTE_TARGET } else { 'aiserver' }),
    [string]$RemoteHeaderBase = $(if ($env:FORGEJO_REMOTE_HEADER_BASE) { $env:FORGEJO_REMOTE_HEADER_BASE } else { '' }),
    [string]$LocalCredentialTarget = $(if ($env:FORGEJO_MIRROR_LOCAL_CREDENTIAL_TARGET) { $env:FORGEJO_MIRROR_LOCAL_CREDENTIAL_TARGET } else { 'forgejomirror-local-api' }),
    [string]$RemoteCredentialTarget = 'forgejo-remote-api',
    [int]$MaxAttempts = 6,
    [int]$DelaySeconds = 10,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'windows-credential.ps1')

function Invoke-RefVerifier {
    param([string]$Path)

    $output = & $Path -RemoteRepoRoot $RemoteRepoRoot -RemoteTarget $RemoteTarget -Json 2>&1
    $exitCode = $LASTEXITCODE
    $jsonText = @($output | Where-Object {
        $_ -is [string] -and $_.TrimStart().StartsWith('{')
    } | Select-Object -First 1)

    if (-not $jsonText) {
        throw "Verifier did not return JSON (exit=$exitCode)."
    }

    $summary = $jsonText | ConvertFrom-Json
    return [pscustomobject]@{
        exitCode = $exitCode
        summary = $summary
    }
}

function ConvertFrom-MirrorRepoName {
    param([string]$Name)

    if ($Name.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
        return $Name.Substring(0, $Name.Length - 4)
    }

    return $Name
}

function Invoke-MirrorSync {
    param(
        [string]$RepoName,
        [string]$BaseUrl,
        [string]$Owner,
        [hashtable]$Headers
    )

    $encodedOwner = [Uri]::EscapeDataString($Owner)
    $encodedRepo = [Uri]::EscapeDataString($RepoName)
    $uri = "$BaseUrl/repos/$encodedOwner/$encodedRepo/mirror-sync"

    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers -TimeoutSec 60 | Out-Null
        return [pscustomobject]@{
            repo = $RepoName
            status = 'triggered'
            http_status = $null
        }
    }
    catch {
        $status = $null
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            repo = $RepoName
            status = 'failed'
            http_status = $status
        }
    }
}

function Invoke-DirectMirrorFetch {
    param(
        [string]$RepoName,
        [string]$Root,
        [string]$RemoteToken,
        [string]$HeaderBase
    )

    $repoPath = Join-Path $Root "$RepoName.git"
    if (-not (Test-Path -LiteralPath $repoPath)) {
        return [pscustomobject]@{
            repo = $RepoName
            status = 'missing_local_bare_repo'
            exit_code = $null
        }
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $resolvedRepo = (Resolve-Path -LiteralPath $repoPath).Path
    if (-not $resolvedRepo.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            repo = $RepoName
            status = 'blocked_outside_mirror_root'
            exit_code = $null
        }
    }

    $oldConfigCount = $env:GIT_CONFIG_COUNT
    $oldConfigKey0 = $env:GIT_CONFIG_KEY_0
    $oldConfigValue0 = $env:GIT_CONFIG_VALUE_0
    $oldErrorActionPreference = $ErrorActionPreference

    try {
        if (-not [string]::IsNullOrWhiteSpace($HeaderBase)) {
            $env:GIT_CONFIG_COUNT = '1'
            $env:GIT_CONFIG_KEY_0 = "http.$($HeaderBase.TrimEnd('/'))/.extraheader"
            $env:GIT_CONFIG_VALUE_0 = "Authorization: token $RemoteToken"
        }

        # Git writes normal fetch progress to stderr. Keep that as command output,
        # not a PowerShell exception, so fallback status is based on the exit code.
        $ErrorActionPreference = 'Continue'
        $output = & git --git-dir=$resolvedRepo fetch --quiet --prune origin '+refs/*:refs/*' 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        if ($null -eq $oldConfigCount) { Remove-Item Env:\GIT_CONFIG_COUNT -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_COUNT = $oldConfigCount }
        if ($null -eq $oldConfigKey0) { Remove-Item Env:\GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_KEY_0 = $oldConfigKey0 }
        if ($null -eq $oldConfigValue0) { Remove-Item Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_VALUE_0 = $oldConfigValue0 }
    }

    return [pscustomobject]@{
        repo = $RepoName
        status = if ($exitCode -eq 0) { 'fetched' } else { 'failed' }
        exit_code = $exitCode
        output_lines = @($output).Count
    }
}

if (-not (Test-Path -LiteralPath $VerifierPath)) {
    throw "Verifier not found: $VerifierPath"
}
if (-not (Test-Path -LiteralPath $MirrorRoot)) {
    throw "Mirror root not found: $MirrorRoot"
}

$initial = Invoke-RefVerifier -Path $VerifierPath
$initialSummary = $initial.summary
$mismatches = @($initialSummary.mismatch | ForEach-Object {
    ConvertFrom-MirrorRepoName -Name ([string]$_)
} | Sort-Object -Unique)

$syncResults = @()
$directFetchResults = @()
$final = $initial

if ($initialSummary.status -ne 'OK' -and $mismatches.Count -gt 0) {
    $token = Get-WindowsGenericCredentialSecret -Target $LocalCredentialTarget
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Missing CredMan target '$LocalCredentialTarget'."
    }

    $headers = @{ Authorization = "token $token" }
    foreach ($repo in $mismatches) {
        $syncResults += Invoke-MirrorSync -RepoName $repo -BaseUrl $ApiBase -Owner $LocalOwner -Headers $headers
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Start-Sleep -Seconds $DelaySeconds
        $final = Invoke-RefVerifier -Path $VerifierPath
        if ($final.summary.status -eq 'OK') {
            break
        }
    }

    if ($final.summary.status -ne 'OK') {
        $remainingMismatches = @($final.summary.mismatch | ForEach-Object {
            ConvertFrom-MirrorRepoName -Name ([string]$_)
        } | Sort-Object -Unique)

        if ($remainingMismatches.Count -gt 0) {
            $remoteToken = Get-WindowsGenericCredentialSecret -Target $RemoteCredentialTarget
            if ([string]::IsNullOrWhiteSpace($remoteToken)) {
                throw "Missing CredMan target '$RemoteCredentialTarget'."
            }

            try {
                foreach ($repo in $remainingMismatches) {
                    $directFetchResults += Invoke-DirectMirrorFetch -RepoName $repo -Root $MirrorRoot -RemoteToken $remoteToken -HeaderBase $RemoteHeaderBase
                }
            }
            finally {
                Remove-Variable remoteToken -ErrorAction SilentlyContinue
            }

            $final = Invoke-RefVerifier -Path $VerifierPath
        }
    }
}

$result = [pscustomobject]@{
    initial_status = $initialSummary.status
    initial_remote_count = $initialSummary.remote_count
    initial_mirror_count = $initialSummary.mirror_count
    initial_missing_count = $initialSummary.missing_count
    initial_extra_count = $initialSummary.extra_count
    initial_mismatch_count = $initialSummary.mismatch_count
    triggered = @($syncResults)
    final_status = $final.summary.status
    final_remote_count = $final.summary.remote_count
    final_mirror_count = $final.summary.mirror_count
    final_missing_count = $final.summary.missing_count
    final_extra_count = $final.summary.extra_count
    final_mismatch_count = $final.summary.mismatch_count
    final_missing = @($final.summary.missing)
    final_extra = @($final.summary.extra)
    final_mismatch = @($final.summary.mismatch)
    direct_fetch = @($directFetchResults)
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5
}
else {
    "INITIAL: status={0} remote={1} mirror={2} missing={3} extra={4} mismatch={5}" -f `
        $result.initial_status, $result.initial_remote_count, $result.initial_mirror_count, `
        $result.initial_missing_count, $result.initial_extra_count, $result.initial_mismatch_count

    foreach ($item in $result.triggered) {
        if ($item.http_status) {
            "SYNC: {0} {1} http={2}" -f $item.repo, $item.status, $item.http_status
        }
        else {
            "SYNC: {0} {1}" -f $item.repo, $item.status
        }
    }

    foreach ($item in $result.direct_fetch) {
        if ($null -ne $item.exit_code) {
            "FETCH: {0} {1} exit={2}" -f $item.repo, $item.status, $item.exit_code
        }
        else {
            "FETCH: {0} {1}" -f $item.repo, $item.status
        }
    }

    "FINAL: status={0} remote={1} mirror={2} missing={3} extra={4} mismatch={5}" -f `
        $result.final_status, $result.final_remote_count, $result.final_mirror_count, `
        $result.final_missing_count, $result.final_extra_count, $result.final_mismatch_count
}

if ($result.final_status -ne 'OK') {
    exit 1
}
