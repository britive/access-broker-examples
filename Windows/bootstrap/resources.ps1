# Simple wrapper script to get AD servers metadata
# This can be called directly or from a batch file

$scriptPath = Join-Path $PSScriptRoot "Get-ADServersMetadata.ps1"

if (Test-Path $scriptPath) {
    & $scriptPath
}
else {
    Write-Error "Get-ADServersMetadata.ps1 not found in the same directory"
    exit 1
}
