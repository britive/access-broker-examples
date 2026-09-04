<#
.SYNOPSIS
    Falcon RTR script (RTR-safe) to revoke temporary local Administrators
    membership, clean up desktop launcher files, terminate elevated processes,
    and notify the interactive user.

.DESCRIPTION
      1. Removes the target account from the local Administrators group (by SID)
      2. Terminates elevated processes spawned by the elevation workflow
      3. Deletes the elevation launcher files from the user's desktop
      4. Sends a modern WinForms notification dialog + system-tray toast

    No logoff is required. The user's session continues with standard privileges.
    Any new runas/elevation attempts will fail because the group membership is gone.

.PARAMETER Username
    SAM account name (for example kk-cstest) or DOMAIN\user. If unqualified, the
    script resolves a local account first, then the machine's AD domain.

.NOTES
    Platform:    Windows 10 / 11
    Run as:      NT AUTHORITY\SYSTEM (RTR default)
    Requires:    RTR Admin or Active Responder with runscript / Execute Operations
    Impact:      Elevated processes will be terminated. User is NOT logged off.
#>

param(
    [string]$Username
)

$ErrorActionPreference = "Stop"

# --- Guard: parameter must be supplied (RTR is non-interactive) ---
if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Output 'ERROR: No -Username supplied. Invoke with: runscript -CloudFile="win-deelevation-v2" -CommandLine="-Username <account>"'
    exit 1
}

$targetUser = $Username.Trim()
$samName = $targetUser.Split('\')[-1]
$qualified = $null
$accountSid = $null

# --- Resolve account scope under SYSTEM context ---
try {
    if ($targetUser -like '*\*') {
        $qualified = $targetUser
    }
    else {
        $localUser = Get-LocalUser -Name $samName -ErrorAction SilentlyContinue
        if ($localUser) {
            $qualified = "$env:COMPUTERNAME\$samName"
        }
        else {
            $cs = Get-CimInstance Win32_ComputerSystem
            if ($cs.PartOfDomain) {
                $qualified = "$($cs.Domain)\$samName"
            }
            else {
                $qualified = "$env:COMPUTERNAME\$samName"
            }
        }
    }

    $accountSid = (New-Object System.Security.Principal.NTAccount($qualified)).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value

    Write-Output "Resolved target account: $qualified (SID $accountSid)"
}
catch {
    Write-Output "ERROR: Could not resolve account '$targetUser'. $_"
    exit 1
}

# =============================================================
# STEP 1: Remove from local Administrators (idempotent, by SID)
# =============================================================
Write-Output ""
Write-Output "STEP 1: Removing user from local Administrators group..."

try {
    $isMember = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop |
        Where-Object { $_.SID.Value -eq $accountSid }

    if (-not $isMember) {
        Write-Output "  User '$qualified' is NOT in the Administrators group. Skipping removal."
    }
    else {
        Remove-LocalGroupMember -Group "Administrators" -Member $qualified -ErrorAction Stop
        Write-Output "  SUCCESS: Removed '$qualified' from local Administrators."
    }
}
catch {
    Write-Output "  ERROR: Failed to remove '$qualified' from Administrators. $_"
    exit 1
}

# Verify removal
try {
    $verify = Get-LocalGroupMember -Group "Administrators" |
        Where-Object { $_.SID.Value -eq $accountSid }

    if ($verify) {
        Write-Output "  ERROR: Verification failed; account is still in Administrators."
        exit 1
    }
    Write-Output "  VERIFIED: '$qualified' is no longer a local Administrator."
}
catch {
    Write-Output "  WARNING: Could not verify group membership removal. $_"
}

# =============================================================
# STEP 2: Terminate elevated processes from the elevation workflow
# =============================================================
Write-Output ""
Write-Output "STEP 2: Terminating elevated processes..."

$killedCount = 0

# PowerShell processes (GUI launcher, elevated shells)
try {
    $psProcesses = Get-Process -Name powershell, pwsh -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -like "*\$samName" }

    foreach ($proc in $psProcesses) {
        try {
            $procId = $proc.Id
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue).CommandLine

            $shouldKill = $false
            if ($cmdLine -match "ElevatedInstaller") { $shouldKill = $true }
            if ($cmdLine -match "Run-Elevated-Installer") { $shouldKill = $true }
            if ($cmdLine -match "-Verb RunAs") { $shouldKill = $true }
            if ($proc.MainWindowTitle -match "Administrator") { $shouldKill = $true }
            if ($proc.MainWindowTitle -match "Elevated.*Launcher") { $shouldKill = $true }

            if ($shouldKill) {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killedCount++
                Write-Output "  KILLED: PowerShell PID $procId - $($proc.MainWindowTitle)"
            }
        }
        catch {
            Write-Output "  WARNING: Could not terminate PowerShell PID $($proc.Id). $_"
        }
    }
}
catch {
    Write-Output "  WARNING: Could not enumerate PowerShell processes. $_"
}

# CMD processes (batch launchers)
try {
    $cmdProcesses = Get-Process -Name cmd -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -like "*\$samName" }

    foreach ($proc in $cmdProcesses) {
        try {
            $procId = $proc.Id
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue).CommandLine

            $shouldKill = $false
            if ($cmdLine -match "Run-Elevated-Installer") { $shouldKill = $true }
            if ($cmdLine -match "runas.*$([regex]::Escape($samName))") { $shouldKill = $true }

            if ($shouldKill) {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killedCount++
                Write-Output "  KILLED: CMD PID $procId"
            }
        }
        catch {
            Write-Output "  WARNING: Could not terminate CMD PID $($proc.Id). $_"
        }
    }
}
catch {
    Write-Output "  WARNING: Could not enumerate CMD processes. $_"
}

# msiexec processes launched by the user
try {
    $msiProcesses = Get-Process -Name msiexec -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -like "*\$samName" }

    foreach ($proc in $msiProcesses) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $killedCount++
            Write-Output "  KILLED: msiexec PID $($proc.Id)"
        }
        catch {
            Write-Output "  WARNING: Could not terminate msiexec PID $($proc.Id). $_"
        }
    }
}
catch {
    Write-Output "  WARNING: Could not enumerate msiexec processes. $_"
}

# runas.exe processes for the target user
try {
    $runasProcesses = Get-Process -Name runas -ErrorAction SilentlyContinue
    foreach ($proc in $runasProcesses) {
        try {
            $procId = $proc.Id
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue).CommandLine
            if ($cmdLine -match [regex]::Escape($samName)) {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killedCount++
                Write-Output "  KILLED: runas PID $procId"
            }
        }
        catch {
            Write-Output "  WARNING: Could not terminate runas PID $($proc.Id). $_"
        }
    }
}
catch {
    Write-Output "  WARNING: Could not enumerate runas processes. $_"
}

if ($killedCount -eq 0) {
    Write-Output "  No elevated processes found to terminate."
}
else {
    Write-Output "  Terminated $killedCount elevated process(es)."
}

# =============================================================
# STEP 3: Delete elevation launcher files from the user's desktop
# =============================================================
Write-Output ""
Write-Output "STEP 3: Cleaning up elevation launcher files..."

$desktopDir = $null
try {
    $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$accountSid'" -ErrorAction Stop
    if ($profile -and $profile.LocalPath) {
        $desktopDir = Join-Path $profile.LocalPath 'Desktop'
    }
}
catch {
    Write-Output "  WARNING: Could not resolve profile via Win32_UserProfile. $_"
}

if (-not $desktopDir -or -not (Test-Path $desktopDir)) {
    try {
        $pip = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$accountSid" -ErrorAction Stop).ProfileImagePath
        if ($pip) { $desktopDir = Join-Path $pip 'Desktop' }
    }
    catch { }
}

$deletedCount = 0

if ($desktopDir -and (Test-Path $desktopDir)) {
    Write-Output "  Target desktop: $desktopDir"

    $filesToDelete = @(
        (Join-Path $desktopDir 'Run-Elevated-Installer.bat'),
        (Join-Path $desktopDir 'ElevatedInstaller.ps1'),
        (Join-Path $desktopDir 'Launch-AdminShell.bat'),
        (Join-Path $desktopDir 'Launch-AdminShell.ps1')
    )

    foreach ($file in $filesToDelete) {
        if (Test-Path $file) {
            try {
                Remove-Item -Path $file -Force -ErrorAction Stop
                $deletedCount++
                Write-Output "  DELETED: $file"
            }
            catch {
                Write-Output "  WARNING: Could not delete $file. $_"
            }
        }
    }

    # Sweep for any other launcher files created by the elevation workflow
    try {
        $suspectFiles = Get-ChildItem -Path $desktopDir -Include "*.bat","*.ps1" -ErrorAction SilentlyContinue |
            Where-Object {
                $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                $content -match "runas.*$([regex]::Escape($samName))" -or
                $content -match "ELEVATED.*LAUNCHER" -or
                $content -match "Elevated Application Launcher"
            }

        foreach ($file in $suspectFiles) {
            try {
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                $deletedCount++
                Write-Output "  DELETED (sweep): $($file.FullName)"
            }
            catch {
                Write-Output "  WARNING: Could not delete $($file.FullName). $_"
            }
        }
    }
    catch {
        Write-Output "  WARNING: Desktop sweep encountered an error. $_"
    }
}
else {
    Write-Output "  WARNING: Could not locate desktop folder for '$qualified'. Skipping file cleanup."
}

Write-Output "  Deleted $deletedCount file(s) total."

# =============================================================
# STEP 4: Notify the user (best effort, never fatal)
# =============================================================
Write-Output ""
Write-Output "STEP 4: Sending notification to user..."

$sessionId = $null
try {
    $quser = quser.exe 2>&1
    foreach ($line in $quser) {
        if ($line -match "(^|\s)>?$([regex]::Escape($samName))(\s|$)") {
            if ($line -match "\s(\d+)\s+(Active|Disc)") {
                $sessionId = $Matches[1]
                break
            }
        }
    }
}
catch { Write-Output "  WARNING: quser failed. $_" }

if (-not $sessionId) {
    try {
        $explorer = Get-Process -Name explorer -IncludeUserName -ErrorAction Stop |
            Where-Object { $_.UserName -like "*\$samName" } | Select-Object -First 1
        if ($explorer) { $sessionId = $explorer.SessionId }
    }
    catch { Write-Output "  WARNING: explorer lookup failed. $_" }
}

if ($sessionId) {
    Write-Output "  Found session id: $sessionId"

    # Modern WinForms notification dialog via scheduled task in the user's session
    try {
        $notifyTask = "RTR_DeElevNotify_$(Get-Random)"
        $notifyScript = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
[void][Console.Window]::ShowWindow([Console.Window]::GetConsoleWindow(), 0)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Security Notification"
$form.Size = New-Object System.Drawing.Size(520, 310)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.TopMost = $true

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 56
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(200, 80, 0)
$form.Controls.Add($headerPanel)

$shieldLabel = New-Object System.Windows.Forms.Label
$shieldLabel.Text = [char]0x1F6E1
$shieldLabel.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 20)
$shieldLabel.ForeColor = [System.Drawing.Color]::White
$shieldLabel.AutoSize = $true
$shieldLabel.Location = New-Object System.Drawing.Point(12, 8)
$headerPanel.Controls.Add($shieldLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Administrator Privileges Revoked"
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(52, 14)
$headerPanel.Controls.Add($titleLabel)

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Text = "Your temporary administrator privileges have been revoked."
$bodyLabel.AutoSize = $false
$bodyLabel.Size = New-Object System.Drawing.Size(470, 26)
$bodyLabel.Location = New-Object System.Drawing.Point(20, 72)
$bodyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($bodyLabel)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.Text = "Any elevated windows have been closed and the launcher scripts have been removed from your desktop. You now have standard user permissions."
$detailLabel.AutoSize = $false
$detailLabel.Size = New-Object System.Drawing.Size(470, 100)
$detailLabel.Location = New-Object System.Drawing.Point(20, 102)
$form.Controls.Add($detailLabel)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Text = "OK"
$okButton.Size = New-Object System.Drawing.Size(100, 36)
$okButton.Location = New-Object System.Drawing.Point(390, 220)
$okButton.BackColor = [System.Drawing.Color]::FromArgb(200, 80, 0)
$okButton.ForeColor = [System.Drawing.Color]::White
$okButton.FlatStyle = "Flat"
$okButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($okButton)

$okButton.Add_Click({ $form.Close() })
$form.CancelButton = $okButton

[System.Windows.Forms.Application]::Run($form)
'@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($notifyScript))
        $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals>
    <Principal id="Author">
      <UserId>$qualified</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <Enabled>true</Enabled>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -EncodedCommand $enc</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        $xmlPath = Join-Path $env:TEMP "$notifyTask.xml"
        $taskXml | Out-File -FilePath $xmlPath -Encoding Unicode -Force
        schtasks.exe /Create /TN $notifyTask /XML $xmlPath /F 2>&1 | Out-Null
        schtasks.exe /Run /TN $notifyTask 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        schtasks.exe /Delete /TN $notifyTask /F 2>&1 | Out-Null
        Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
        Write-Output "  Notification dialog launched in user session."
    }
    catch { Write-Output "  WARNING: notification dialog failed. $_" }

    # Supplementary system-tray toast (non-blocking, auto-dismisses)
    try {
        $toastTask = "RTR_DeElevToast_$(Get-Random)"
        $toastScript = @'
Add-Type -AssemblyName System.Windows.Forms
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Warning
$n.BalloonTipIcon = "Warning"
$n.BalloonTipTitle = "Admin Privileges Revoked"
$n.BalloonTipText = "Your temporary admin privileges have been removed. You now have standard user permissions."
$n.Visible = $true
$n.ShowBalloonTip(30000)
Start-Sleep -Seconds 35
$n.Dispose()
'@
        $enc2 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))
        $toastXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals>
    <Principal id="Author">
      <UserId>$qualified</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <Enabled>true</Enabled>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -EncodedCommand $enc2</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        $xmlPath2 = Join-Path $env:TEMP "$toastTask.xml"
        $toastXml | Out-File -FilePath $xmlPath2 -Encoding Unicode -Force
        schtasks.exe /Create /TN $toastTask /XML $xmlPath2 /F 2>&1 | Out-Null
        schtasks.exe /Run /TN $toastTask 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        schtasks.exe /Delete /TN $toastTask /F 2>&1 | Out-Null
        Remove-Item $xmlPath2 -Force -ErrorAction SilentlyContinue
        Write-Output "  Toast queued in user session."
    }
    catch { Write-Output "  WARNING: toast notification failed. $_" }
}
else {
    Write-Output "  WARNING: No active session found for '$samName'. Could not send notification."
    Write-Output "  Changes will take effect at next sign-in."
}

# =============================================================
# SUMMARY
# =============================================================
Write-Output ""
Write-Output "============================================================"
Write-Output "REVOCATION COMPLETE"
Write-Output "============================================================"
Write-Output ""
Write-Output "  Account:        $qualified"
Write-Output "  Admin group:    REMOVED"
Write-Output "  Processes:      TERMINATED $killedCount elevated process(es)"
Write-Output "  Launcher files: DELETED $deletedCount file(s) from desktop"
Write-Output "  Notification:   $(if ($sessionId) { 'SENT' } else { 'SKIPPED (no session)' })"
Write-Output ""
Write-Output "  User session:   PRESERVED (no logoff performed)"
Write-Output ""
Write-Output "The user can continue working with standard privileges."
Write-Output "Any new elevation attempts (runas, Run as administrator) will fail."
Write-Output "============================================================"

exit 0