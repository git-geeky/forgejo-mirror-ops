$script:CredManTypeLoaded = $false

function Initialize-WindowsCredentialApi {
    if ($script:CredManTypeLoaded) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeCredMan {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public UInt32 Flags;
        public UInt32 Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;
        public UInt32 Persist;
        public UInt32 AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredRead(string target, UInt32 type, UInt32 reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite(ref CREDENTIAL userCredential, UInt32 flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr buffer);
}
'@

    $script:CredManTypeLoaded = $true
}

function Get-WindowsGenericCredentialSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    Initialize-WindowsCredentialApi
    $ptr = [IntPtr]::Zero
    $ok = [NativeCredMan]::CredRead($Target, 1, 0, [ref]$ptr)
    if (-not $ok) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Credential '$Target' not found or unreadable (Win32=$code)"
    }

    try {
        $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][NativeCredMan+CREDENTIAL])
        if ($cred.CredentialBlobSize -eq 0 -or $cred.CredentialBlob -eq [IntPtr]::Zero) {
            return ''
        }

        return [Runtime.InteropServices.Marshal]::PtrToStringUni(
            $cred.CredentialBlob,
            [int]($cred.CredentialBlobSize / 2)
        )
    }
    finally {
        [NativeCredMan]::CredFree($ptr)
    }
}

function Set-WindowsGenericCredentialSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,

        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [string]$Secret
    )

    Initialize-WindowsCredentialApi
    $secretBytes = [Text.Encoding]::Unicode.GetBytes($Secret)
    $blob = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($Secret)
    try {
        $cred = [NativeCredMan+CREDENTIAL]::new()
        $cred.Type = 1
        $cred.TargetName = $Target
        $cred.UserName = $UserName
        $cred.CredentialBlob = $blob
        $cred.CredentialBlobSize = [uint32]$secretBytes.Length
        $cred.Persist = 2

        $ok = [NativeCredMan]::CredWrite([ref]$cred, 0)
        if (-not $ok) {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Failed to write credential '$Target' (Win32=$code)"
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($blob)
    }
}
