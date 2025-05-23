# Read input variables from environment
$Action = $env:BRITIVE_ACTION
$Instance = $env:INSTANCE
$Sudo = $env:BRITIVE_SUDO
if (-not $Sudo) { $Sudo = "0" }

$UserEmail = $env:BRITIVE_USER_EMAIL
if (-not $UserEmail) { $UserEmail = "test@example.com" }

$Username = ($UserEmail -split "@")[0] -replace '[^a-zA-Z0-9]', ''
$User = $Username
$Group = $Username

if ($Action -eq "checkout") {
    $KeyDir = New-TemporaryFile | Split-Path
    $KeyPath = Join-Path $KeyDir "britive-id_rsa"
    & ssh-keygen -q -N "" -t rsa -f $KeyPath

    $PubKey = Get-Content "$KeyPath.pub" -Raw

    # Parameters as hashtable
    $ParamHash = @{
        username     = @($User)
        group        = @($Group)
        sshPublicKey = @($PubKey)
        sudo         = @($Sudo)
        userEmail    = @($UserEmail)
    }

    # Convert to JSON
    $ParamsJson = $ParamHash | ConvertTo-Json -Compress -Depth 3

    # Write to temporary file (best for long string compatibility)
    $TempParamsFile = New-TemporaryFile
    Set-Content -Path $TempParamsFile -Value $ParamsJson

    # Send command using parameter file
    $CommandId = aws ssm send-command `
        --document-name "addSSHKey" `
        --targets "Key=InstanceIds,Values=$Instance" `
        --parameters file://$TempParamsFile `
        --region "us-west-2" `
        --query "Command.CommandId" `
        --output text

    if (-not $CommandId) {
        Write-Error "Failed to send command"
        exit 1
    }

    while ($true) {
        $Status = aws ssm list-command-invocations `
            --command-id $CommandId `
            --details `
            --region "us-west-2" `
            --query "CommandInvocations[0].Status" `
            --output text

        if ($Status -eq "Success") {
            break
        } elseif ($Status -in @("Failed", "Cancelled", "TimedOut")) {
            Write-Error "Command failed with status: $Status"
            exit 1
        } else {
            Start-Sleep -Seconds 2
        }
    }

    Get-Content $KeyPath
    # Cleanup: Delete local key files
    Remove-Item -Path $KeyPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$KeyPath.pub" -Force -ErrorAction SilentlyContinue

    # Optional: Convert .pem to .ppk using PuTTYgen if available
    <#$PpkPath = "$KeyPath.ppk"

    if (Get-Command "puttygen.exe" -ErrorAction SilentlyContinue) {
        Write-Host "Converting $KeyPath to PuTTY .ppk format"
        & puttygen.exe $KeyPath -O private -o $PpkPath

        if (Test-Path $PpkPath) {
            Get-Content $PpkPath"
            Remove-Item -Path $PpkPath -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Warning "Failed to convert to .ppk format."
        }
    }
    else {
        Write-Warning "PuTTYgen not found in PATH. Skipping .ppk conversion."
    }#>
}
else {
    Write-Host "Removing user $User from instance $Instance"

    $RemoveParams = @{
        username = @($User)
    }

    $RemoveParamsJson = $RemoveParams | ConvertTo-Json -Compress
    $RemoveParamsFile = New-TemporaryFile
    Set-Content -Path $RemoveParamsFile -Value $RemoveParamsJson

    aws ssm send-command `
        --document-name "removeSSHKey" `
        --targets "Key=InstanceIds,Values=$Instance" `
        --parameters file://$RemoveParamsFile `
        --region "us-west-2"
}
