# britive-ssh.ps1

# Read input variables from environment
$Action = $env:BRITIVE_ACTION       # Action to perform: 'checkout' (create user) or 'checkin' (remove user)
$Instance = $env:INSTANCE           # Target EC2 instance ID
$Sudo = $env:BRITIVE_SUDO           # Whether to grant sudo access (optional)
if (-not $Sudo) { $Sudo = "0" }     # Default to "0" (no sudo) if not set

# Get the user's email from environment, or use default for testing
$UserEmail = $env:BRITIVE_USER_EMAIL
if (-not $UserEmail) { $UserEmail = "test@example.com" }

# Extract username from email (before @) and remove any non-alphanumeric characters
$Username = ($UserEmail -split "@")[0] -replace '[^a-zA-Z0-9]', ''

# Set the user and group name to the cleaned username
$User = $Username
$Group = $Username

# Handle 'checkout' operation (create user, generate key, send public key via SSM)
if ($Action -eq "checkout") {
    Write-Host "Generating SSH key pair for $Username for instance: $Instance"

    # Create a temporary directory for the SSH key pair
    $KeyDir = New-TemporaryFile | Split-Path
    $KeyPath = Join-Path $KeyDir "britive-id_rsa"

    # Generate an RSA SSH key pair with no passphrase
    & ssh-keygen -q -N "" -t rsa -f $KeyPath

    # Read the public key content
    $PubKey = Get-Content "$KeyPath.pub" -Raw

    Write-Host "Sending public key to EC2 via SSM"

    # Send the public key and user info to the EC2 instance using an SSM document
    $CommandId = aws ssm send-command `
        --document-name "addSSHKey" `
        --targets "Key=InstanceIds,Values=$Instance" `
        --parameters @{ 
            username = @($User); 
            group = @($Group); 
            sshPublicKey = @($PubKey); 
            sudo = @($Sudo); 
            userEmail = @($UserEmail) 
        } `
        --region "us-west-2" `
        --query "Command.CommandId" `
        --output text

    # Check if the SSM command was successfully initiated
    if (-not $CommandId) {
        Write-Error "Failed to send command"
        exit 1
    }

    Write-Host "Waiting for SSM command ($CommandId) to complete..."

    # Poll the status of the SSM command until it completes or fails
    while ($true) {
        $Status = aws ssm list-command-invocations `
            --command-id $CommandId `
            --details `
            --region "us-west-2" `
            --query "CommandInvocations[0].Status" `
            --output text

        if ($Status -eq "Success") {
            Write-Host "Command completed successfully."
            break
        }
        elseif ($Status -in @("Failed", "Cancelled", "TimedOut")) {
            Write-Error "Command failed with status: $Status"
            exit 1
        }
        else {
            Start-Sleep -Seconds 2  # Wait a bit before checking again
        }
    }

    # Output the private key so it can be retrieved by the automation platform
    Get-Content $KeyPath
}
else {
    # Handle 'checkin' operation (remove user from instance)
    Write-Host "Removing user $User from instance $Instance"

    # Send the removal command via SSM
    aws ssm send-command `
        --document-name "removeSSHKey" `
        --targets "Key=InstanceIds,Values=$Instance" `
        --parameters @{ username = @($User) } `
        --region "us-west-2"
}
