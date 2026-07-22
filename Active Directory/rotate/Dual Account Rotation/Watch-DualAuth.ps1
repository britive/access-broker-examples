# Watch-DualAuth.ps1
# Live auth timeline for the dual-account rotation demo.
#
#   .\Watch-DualAuth.ps1 -Simulate             # rehearse with active.txt, no tenant
#   .\Watch-DualAuth.ps1                       # live against Britive dual-account secret
#   .\Watch-DualAuth.ps1 -Static svc-webapp-a  # single-account BASELINE (watch it break)

[CmdletBinding()]
param(
    [switch]$Simulate,
    [string]$Static,                 # if set, pin to ONE account (the "before" case)
    [string]$Domain   = "example.local",
    [int]   $IntervalSeconds = 3,
    [string]$StaticPassword          # only needed with -Static; prompts if omitted
)

$ErrorActionPreference = 'Stop'

# ---- Fail-fast setup ----
$helper = Join-Path $PSScriptRoot 'Get-ActiveCred.ps1'
if (-not (Test-Path $helper)) {
    Write-Error "Missing dependency: $helper"
    exit 1
}

try {
    . $helper
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
    $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $Domain)
}
catch {
    Write-Error "Failed to initialize domain context for '$Domain': $($_.Exception.Message)"
    exit 1
}

# Mask a password to just its last two chars, e.g. "hT6^ofXs" -> "******Xs"
function Format-Masked([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "(none)" }
    if ($s.Length -le 2) { return ('*' * $s.Length) }
    return ('*' * ($s.Length - 2)) + $s.Substring($s.Length - 2)
}

if ($Static -and -not $StaticPassword) {
    $StaticPassword = Read-Host "Password for $Static" -AsSecureString |
        ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
}

Write-Host "Watching auth every ${IntervalSeconds}s. Ctrl+C to stop.`n" -ForegroundColor Cyan

# Loop is intentionally resilient: a transient error on one tick is logged and
# the watch continues, so the timeline keeps ticking through a rotation.
while ($true) {
    $ts = Get-Date -Format "HH:mm:ss"
    try {
        if ($Static) {
            $user = $Static; $pass = $StaticPassword; $res = $Domain   # baseline
        } else {
            $cred = Get-ActiveCred -Simulate:$Simulate                  # dual: active side
            $user = $cred.Username; $pass = $cred.Password
            $res  = if ($cred.Resource) { $cred.Resource } else { $Domain }
        }

        $masked = Format-Masked $pass
        $ok = $ctx.ValidateCredentials($user, $pass)
        if ($ok) {
            Write-Host ("[{0}] SUCCESS  active={1,-14} resource={2,-10} pwd={3}" -f $ts, $user, $res, $masked) -ForegroundColor Green
        } else {
            Write-Host ("[{0}] FAIL     active={1,-14} resource={2,-10} pwd={3}  (bind rejected)" -f $ts, $user, $res, $masked) -ForegroundColor Red
        }
    } catch {
        Write-Host "[$ts] FAIL     $($_.Exception.Message)" -ForegroundColor Red
    }
    Start-Sleep -Seconds $IntervalSeconds
}
