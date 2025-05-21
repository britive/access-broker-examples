<#
.SYNOPSIS
    Just-In-Time access automation using AWS EC2 tags and SSM Documents.

.DESCRIPTION
    This script looks up EC2 instances based on tag filters and executes SSM documents
    to either grant or revoke temporary local admin access on Windows instances.

.PARAMETER Region
    AWS region to operate in. Default is 'us-west-2'.

.EXAMPLE
    .\jit_access.ps1 -Region "us-west-2"
#>

param (
    [string]$Region = $env:AWS_REGION
)

if (-not $Region) {
    $Region = "us-west-2"
}
function Get-InstanceIdsByTags {
    param (
        [hashtable]$TagFilters
    )

    try {
        $filters = @()
        foreach ($tagKey in $TagFilters.Keys) {
            $tagValues = $TagFilters[$tagKey]
            if ($tagValues -is [string]) {
                $tagValues = $tagValues -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }
            $filters += @{
                Name   = "tag:$tagKey"
                Values = $tagValues
            }
        }

        $instanceIds = @()
        $nextToken = $null

        do {
            $result = Get-EC2Instance -Region $Region -Filter $filters -NextToken $nextToken
            foreach ($reservation in $result.Reservations) {
                foreach ($instance in $reservation.Instances) {
                    if ($instance.State.Name -eq "running") {
                        $instanceIds += $instance.InstanceId
                    }
                }
            }
            $nextToken = $result.NextToken
        } while ($nextToken)

        return $instanceIds | Select-Object -Unique
    }
    catch {
        Write-Error "[ERROR] Failed to retrieve instance IDs: $_"
        exit 1
    }
}

function Send-SSMCommand {
    param (
        [string[]]$InstanceIds,
        [string]$DocumentName,
        [hashtable]$Parameters,
        [string]$Comment
    )

    try {
        $response = Send-SSMCommand `
            -DocumentName $DocumentName `
            -InstanceId $InstanceIds `
            -Parameter $Parameters `
            -Comment $Comment `
            -Region $Region

        return $response.Command.CommandId
    }
    catch {
        Write-Error "[ERROR] Failed to send SSM command: $_"
        exit 1
    }
}

function Main {
    $rawTags = $env:JIT_TAGS
    $user = $env:USER
    $mode = $env:JIT_ACTION
    if (-not $mode) { $mode = "checkout" }

    if (-not $rawTags -or -not $user) {
        Write-Error "[ERROR] Missing required environment variables: JIT_TAGS and USER"
        exit 1
    }

    try {
        $tagFilters = $null
        try {
            $tagFilters = ConvertFrom-Json $rawTags
        }
        catch {
            Write-Error "[ERROR] Failed to parse JIT_TAGS JSON: $_"
            exit 1
        }

        $instanceIds = Get-InstanceIdsByTags -TagFilters $tagFilters

        if (-not $instanceIds) {
            Write-Error "[ERROR] No matching instances found."
            exit 1
        }

        if ($mode -eq "checkout") {
            $commandId = Send-SSMCommand -InstanceIds $instanceIds -DocumentName "AddLocalAdminADUser" -Parameters @{ "username" = @($user) } -Comment "Granting Windows local admin access to $user"
            Write-Host "✅ Windows access granted via SSM. Command ID: $commandId"
        }
        elseif ($mode -eq "checkin") {
            $commandId = Send-SSMCommand -InstanceIds $instanceIds -DocumentName "RemoveLocalADUser" -Parameters @{ "username" = @($user) } -Comment "Revoking temporary access for $user"
            Write-Host "🧹 Windows access revoked via SSM. Command ID: $commandId"
        }
        else {
            Write-Error "[ERROR] Unknown JIT_ACTION '$mode'. Use 'checkout' or 'checkin'."
            exit 1
        }
    }
    catch {
        Write-Error "[ERROR] Unexpected error: $_"
        exit 1
    }
}

Main
