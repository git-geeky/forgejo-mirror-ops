param(
    [string]$TaskName = $(if ($env:FORGEJO_MIRROR_SYNC_TASK) { $env:FORGEJO_MIRROR_SYNC_TASK } else { 'ForgejoMirrorSync-Daily' }),
    [string]$HiddenRunner = $(if ($env:FORGEJO_MIRROR_HIDDEN_RUNNER) { $env:FORGEJO_MIRROR_HIDDEN_RUNNER } else { Join-Path $env:USERPROFILE 'bin\run-ps-hidden.vbs' }),
    [string]$SyncScript = $(if ($env:FORGEJO_MIRROR_SYNC_SCRIPT) { $env:FORGEJO_MIRROR_SYNC_SCRIPT } else { Join-Path $PSScriptRoot 'sync-new-repos.ps1' }),
    [Parameter(Mandatory = $true)]
    [string]$RemoteUrl,
    [string]$RemoteCloneBase = $(if ($env:FORGEJO_REMOTE_CLONE_BASE) { $env:FORGEJO_REMOTE_CLONE_BASE } else { '' })
)

$ErrorActionPreference = 'Stop'

$syncArgs = @('-RemoteUrl', ('"{0}"' -f $RemoteUrl))
if (-not [string]::IsNullOrWhiteSpace($RemoteCloneBase)) {
    $syncArgs += @('-RemoteCloneBase', ('"{0}"' -f $RemoteCloneBase))
}

$action = New-ScheduledTaskAction `
    -Execute 'wscript.exe' `
    -Argument ('"{0}" "{1}" {2}' -f $HiddenRunner, $SyncScript, ($syncArgs -join ' '))

Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null

schtasks /Query /TN $TaskName /FO LIST /V |
    Select-String -Pattern 'TaskName:|Status:|Scheduled Task State:|Task To Run:|Last Result:'
