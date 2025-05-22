param(
    [string]$Region = "us-west-2",
    [string]$ProfileName = $env:AWS_PROFILE
)

Import-Module AWSPowerShell.NetCore -ErrorAction Stop

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

    return $filters
}


function Get-InstanceIdsByTags {
    param (
        [hashtable]$TagFilters
    )

    $filters = @()
    foreach ($key in $TagFilters.Keys) {
        $values = $TagFilters[$key]
        if ($values -is [string]) {
            $values = $values -split "," | ForEach-Object { $_.Trim() }
        }
        $filters += @{ Name = "tag:$key"; Values = $values }
    }

    try {
        $response = Get-EC2Instance -Region $Region -ProfileName $ProfileName -Filter $filters
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
        [string]$Comment
    )

    try {
        $command = Send-SSMCommand -DocumentName $DocumentName `
            -InstanceIds $InstanceIds `
            -Parameters $Parameters `
            -Comment $Comment `
            -Region $Region `
            -ProfileName $ProfileName
        
        $cmdId = $command.CommandId
        return $cmdId
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

    try {
        $tagFilters = Convert-JsonToEC2TagFilters -JsonString $rawTags
        $instances = Get-EC2Instance -Region $Region -Filter $tagFilters

        # Extract running instance IDs
        $instanceIds = $instances.Instances | Where-Object { $_.State.Name -eq 'running' } | Select-Object -ExpandProperty InstanceId

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
                    -Comment "Granting Windows local admin access to $user"
                Write-Output "✅ Windows access granted via SSM. Command ID: $cmdId"
            }
            "checkin" {
                $cmdId = Invoke-SSMCommand -InstanceIds $instanceIds `
                    -DocumentName "RemoveLocalADUser" `
                    -Parameters @{ username = @($user) } `
                    -Comment "Revoking temporary access for $user"
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
