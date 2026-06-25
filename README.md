# Local Forgejo Mirror

This directory owns a Windows-side local Forgejo mirror for an upstream Forgejo
instance. The upstream forge remains authoritative; this local service is a
read-only convenience and disaster-recovery cache for a workstation.

This git repo tracks only source files and sanitized examples. Live mirror data,
SQLite files, bare repos, logs, backups, upgrade scratch directories, and
`shadow\app.ini` are intentionally ignored. Do not stage runtime state or
secret-bearing config.

Current live endpoint:

- `http://127.0.0.1:3300`
- container: `local-forgejo-mirror`
- image: `codeberg.org/forgejo/forgejo:15.0.3-rootless`
- data root: `<repo>\shadow`

Daily discovery of new remote repos is handled by the Windows task
`ForgejoMirrorSync-Daily`, which runs:

```powershell
.\sync-new-repos.ps1 -RemoteUrl https://forge.example.com/api/v1
```

Full-ref integrity verification is handled by:

```powershell
.\Test-ForgejoMirrorRefs.ps1 -RemoteRepoRoot /srv/git/repositories/owner
```

It compares sorted `git show-ref --head` hashes for every remote repo under
the configured upstream repository root against local bare mirrors under
`shadow\repos\mirror-admin`, then writes current state to:

- `C:\ProgramData\ForgejoMirror\sync-state.txt`
- `C:\ProgramData\ForgejoMirror\logs\integrity-check.log`

If verification reports only mismatched refs, repair those mirrors with:

```powershell
.\Sync-ForgejoMirrorDrift.ps1
```

The drift repair script uses the existing verifier JSON, triggers the local
Forgejo `/mirror-sync` endpoint only for mismatched repos, and reruns the
verifier until it returns `OK` or the retry budget is exhausted.

`C:\ProgramData\GiteaMirror` is historical state from the pre-Docker/pre-Forgejo
mirror path. Do not use it as a current health source.
