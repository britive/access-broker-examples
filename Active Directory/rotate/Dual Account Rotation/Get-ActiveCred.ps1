# Get-ActiveCred.ps1
# Returns the currently-active credential from a Britive dual-account secret.
#
# In dual-account rotation, only one of the two accounts (A or B) is "active" at
# any moment. Retrieving the dual-account secret always yields the ACTIVE side,
# so a consumer never has to know which account is live.

function Get-ActiveCred {
    [CmdletBinding()]
    param(
        [switch]$Simulate,
        [string]$SecretPath = "/IT Secrets/WebApp Dual Account",
        [string]$SimFile    = "$PSScriptRoot\active.txt"
    )

    $ErrorActionPreference = 'Stop'

    if ($Simulate) {
        # Rehearsal mode: read "username|password" from a local file.
        # Flip A/B in this file by hand to fake a rotation.
        if (-not (Test-Path $SimFile)) {
            throw "Simulate mode: file not found: $SimFile (expected 'username|password')"
        }
        $line = (Get-Content $SimFile -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "Simulate mode: $SimFile is empty (expected 'username|password')"
        }
        $u, $p = $line -split '\|', 2
        if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)) {
            throw "Simulate mode: malformed line in $SimFile (expected 'username|password')"
        }
        return [pscustomobject]@{ Username = $u; Password = $p }
    }

    # ---- REAL BRITIVE CALL (adjust field names to your secret template) ----
    # Using pybritive; retrieving the dual-account secret yields the ACTIVE side.
    if (-not (Get-Command pybritive -ErrorAction SilentlyContinue)) {
        throw "pybritive CLI not found on PATH. Install it or use -Simulate."
    }

    $raw = pybritive secret view $SecretPath --format json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "pybritive failed to read '$SecretPath': $raw"
    }

    try {
        $json = $raw | ConvertFrom-Json
    } catch {
        throw "Could not parse pybritive output as JSON for '$SecretPath': $($_.Exception.Message)"
    }

    # Map these to your static-secret template's field names:
    if (-not $json.account -or -not $json.password) {
        throw "Secret '$SecretPath' missing expected fields 'account'/'password'."
    }

    return [pscustomobject]@{
        Username = $json.account
        Password = $json.password
    }
}
