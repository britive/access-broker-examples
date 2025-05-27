param(
    [string]$Region = $env:REGION,
    [string]$TargetRoleArn = $env:ASSUME_ROLE_ARN
)

function Convert-Username {
    param(
        [string]$Username,
        [string]$Domain = "AD\"
    )
    if ($Username -match "@" -and $Username -match "\.") {
        $emailPrefix = $Username.Split("@")[0]
        return "$Domain$emailPrefix"
    } else {
        return $null
    }
}

function Convert-JsonToEC2TagFilters {
    param(
        [Parameter(Mandatory)]
        [string]$JsonString
    )

    $parsed = ConvertFrom-Json $JsonString
    $filters = @()

    foreach ($key in $parsed.PSObject.Properties.Name) {
        $values = $parsed.$key
        if ($values -is [string]) {
            $values = $values -split "," | ForEach-Object { $_.Trim() }
        }
        $filters += @{ Name = "tag:$key"; Values = $values }
    }

    return $filters | ForEach-Object {
        New-Object -TypeName Amazon.EC2.Model.Filter -Property $_
    }
}

function ConvertTo-SecureStringObject {
    param (
        [string]$AccessKeyId,
        [string]$SecretAccessKey,
        [string]$SessionToken
    )

    return [PSCustomObject]@{
        AccessKeyId     = $AccessKeyId
        SecretAccessKey = ($SecretAccessKey | ConvertTo-SecureString -AsPlainText -Force)
        SessionToken    = ($SessionToken | ConvertTo-SecureString -AsPlainText -Force)
    }
}

function Set-CrossAccountRole {
    param (
        [string]$RoleArn,
        [string]$SessionName = "JITSession"
    )

    try {
        $creds = Use-STSRole -RoleArn $RoleArn -RoleSessionName $SessionName -Region $Region
        return ConvertTo-SecureStringObject `
            -AccessKeyId $creds.Credentials.AccessKeyId `
            -SecretAccessKey $creds.Credentials.SecretAccessKey `
            -SessionToken $creds.Credentials.SessionToken
    } catch {
        Write-Error "[ERROR] Failed to assume role: $_"
        exit 1
    }
}

function Get-InstanceIdsByTags {
    param (
        [array]$TagFilters,
        [object]$AssumedCreds
    )

    # Decode secure strings
    $AccessKeyId = $AssumedCreds.AccessKeyId
    $SecretKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AssumedCreds.SecretAccessKey))
    $SessionToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AssumedCreds.SessionToken))

    # Create AWS credential object
    $awsCreds = New-Object -TypeName Amazon.Runtime.SessionAWSCredentials -ArgumentList $AccessKeyId, $SecretKey, $SessionToken

    try {
        $response = Get-EC2Instance `
            -Region $Region `
            -Credential $awsCreds `
            -Filter $TagFilters

        $instanceIds = $response.Reservations.Instances |
            Where-Object { $_.State.Name -eq "running" } |
            Select-Object -ExpandProperty InstanceId -Unique

        return $instanceIds
    } catch {
        Write-Error "[ERROR] Failed to retrieve instance IDs: $_"
        exit 1
    }
}

function Invoke-SSMCommand {
    param (
        [array]$InstanceIds,
        [string]$DocumentName,
        [hashtable]$Parameters,
        [string]$Comment,
        [object]$AssumedCreds
    )

    try {
        $command = Send-SSMCommand -DocumentName $DocumentName `
            -InstanceIds $InstanceIds `
            -Parameters $Parameters `
            -Comment $Comment `
            -Region $Region `
            -AccessKey $AssumedCreds.AccessKeyId `
            -SecretKey ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AssumedCreds.SecretAccessKey))) `
            -SessionToken ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AssumedCreds.SessionToken)))

        return $command.CommandId
    } catch {
        Write-Error "[ERROR] Failed to send SSM command: $_"
        exit 1
    }
}

function Main {
    $rawTags = $env:JIT_TAGS
    $domain = $env:DOMAIN
    $user = Convert-Username -Username $env:USER -Domain $domain
    $mode = $env:JIT_ACTION
    if (-not $mode) { $mode = "checkout" }

    if (-not $rawTags -or -not $user) {
        Write-Error "[ERROR] Missing required environment variables: JIT_TAGS and USER"
        exit 1
    }

    Write-Output "[INFO] Assuming role: $TargetRoleArn"
    $assumedCreds = Set-CrossAccountRole -RoleArn $TargetRoleArn

    try {
        $tagFilters = Convert-JsonToEC2TagFilters -JsonString $rawTags

        $instanceIds = Get-InstanceIdsByTags -TagFilters $tagFilters -AssumedCreds $assumedCreds

        if (-not $instanceIds -or $instanceIds.Count -eq 0) {
            Write-Error "[ERROR] No matching instances found."
            exit 1
        }

        Write-Output "[INFO] Username: $user"
        Write-Output "[INFO] Instance IDs: $($instanceIds -join ', ')"

        switch ($mode) {
            "checkout" {
                $cmdId = Invoke-SSMCommand -InstanceIds $instanceIds `
                    -DocumentName "AddLocalAdminADUser" `
                    -Parameters @{ username = @($user) } `
                    -Comment "Granting Windows local admin access to $user" `
                    -AssumedCreds $assumedCreds
                Write-Output "✅ Windows access granted via SSM. Command ID: $cmdId"
            }
            "checkin" {
                $cmdId = Invoke-SSMCommand -InstanceIds $instanceIds `
                    -DocumentName "RemoveLocalADUser" `
                    -Parameters @{ username = @($user) } `
                    -Comment "Revoking temporary access for $user" `
                    -AssumedCreds $assumedCreds
                Write-Output "🧹 Windows access revoked via SSM. Command ID: $cmdId"
            }
            Default {
                Write-Error "[ERROR] Unknown JIT_ACTION '$mode'. Use 'checkout' or 'checkin'."
                exit 1
            }
        }
    } catch {
        Write-Error "[ERROR] Unexpected error: $_"
        exit 1
    }
}

Main
# End of script