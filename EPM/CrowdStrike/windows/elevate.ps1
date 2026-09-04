<#
.SYNOPSIS
    Falcon RTR script (RTR-safe) to grant a named local account temporary local
    Administrators membership, notify the interactive user, and place an elevation
    launcher on that user's desktop.

.DESCRIPTION
    NOTE on the runas hop in the launcher: adding the account to Administrators does
    NOT update an existing logon session's token. A user who is already signed in
    keeps a non-admin token until next logon, and UAC elevation reuses that session's
    linked token. The launcher therefore uses runas to force a fresh logon that
    includes the new group membership, then UAC-elevates from there.

.PARAMETER Username
    SAM account name (for example kk-cstest) or DOMAIN\user. If unqualified, the
    script resolves a local account first, then the machine's AD domain.

.NOTES
    Platform:    Windows 10 / 11
    Run as:      NT AUTHORITY\SYSTEM (RTR default)
    Requires:    RTR Admin or Active Responder with runscript / Execute Operations
    Impact:      Target user is added to local Administrators and receives a desktop
                 notification and launcher. Standing membership persists until removed.
#>

param(
    [string]$Username
)

$ErrorActionPreference = "Stop"

# --- Guard: parameter must be supplied (RTR is non-interactive) ---
if ([string]::IsNullOrWhiteSpace($Username)) {
    Write-Output 'ERROR: No -Username supplied. Invoke with: runscript -CloudFile="win-elevation-v3" -CommandLine="-Username <account>"'
    exit 1
}

$targetUser = $Username.Trim()
# Bare SAM name used for session / profile lookups (strip any domain prefix)
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

# --- Step 1: Add to local Administrators (idempotent, by SID) ---
try {
    $isMember = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop |
        Where-Object { $_.SID.Value -eq $accountSid }

    if ($isMember) {
        Write-Output "User '$qualified' is already a local Administrator."
    }
    else {
        Add-LocalGroupMember -Group "Administrators" -Member $qualified -ErrorAction Stop
        Write-Output "SUCCESS: Added '$qualified' to local Administrators."
    }
}
catch {
    Write-Output "ERROR: Failed to add '$qualified' to local Administrators. $_"
    exit 1
}

# --- Step 2: Verify membership ---
try {
    $verify = Get-LocalGroupMember -Group "Administrators" |
        Where-Object { $_.SID.Value -eq $accountSid }
    if (-not $verify) {
        Write-Output "ERROR: Verification failed; account not present in Administrators."
        exit 1
    }
    Write-Output "VERIFIED: '$qualified' is a member of local Administrators."
}
catch {
    Write-Output "WARNING: Could not verify membership. $_"
}

# --- Step 3: Resolve the user's profile / desktop from the SID ---
$desktopDir = $null
try {
    $profile = Get-CimInstance Win32_UserProfile -Filter "SID='$accountSid'" -ErrorAction Stop
    if ($profile -and $profile.LocalPath) {
        $desktopDir = Join-Path $profile.LocalPath 'Desktop'
    }
}
catch {
    Write-Output "WARNING: Could not resolve profile via Win32_UserProfile. $_"
}

if (-not $desktopDir -or -not (Test-Path $desktopDir)) {
    try {
        $pip = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$accountSid" -ErrorAction Stop).ProfileImagePath
        if ($pip) { $desktopDir = Join-Path $pip 'Desktop' }
    }
    catch { }
}

if (-not $desktopDir -or -not (Test-Path $desktopDir)) {
    Write-Output "ERROR: Could not locate the desktop folder for '$qualified'. Has the user signed in at least once?"
    exit 1
}
Write-Output "Target desktop: $desktopDir"

# --- Step 4: Find the interactive session id (for notifications) ---
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
catch { Write-Output "WARNING: quser failed. $_" }

if (-not $sessionId) {
    try {
        $explorer = Get-Process -Name explorer -IncludeUserName -ErrorAction Stop |
            Where-Object { $_.UserName -like "*\$samName" } | Select-Object -First 1
        if ($explorer) { $sessionId = $explorer.SessionId }
    }
    catch { Write-Output "WARNING: explorer lookup failed. $_" }
}

# --- Step 5: Notify the interactive user (best effort, never fatal) ---
if ($sessionId) {
    Write-Output "Found session id: $sessionId"

    try {
        $notifyTask = "RTR_ElevNotify_$(Get-Random)"
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
$form.Size = New-Object System.Drawing.Size(520, 340)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.BackColor = [System.Drawing.SystemColors]::Window
$form.ForeColor = [System.Drawing.SystemColors]::WindowText
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.TopMost = $true

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 56
$headerPanel.BackColor = [System.Drawing.SystemColors]::Highlight
$form.Controls.Add($headerPanel)

$shieldLabel = New-Object System.Windows.Forms.Label
$shieldLabel.Text = [char]0x1F6E1
$shieldLabel.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 20)
$shieldLabel.ForeColor = [System.Drawing.SystemColors]::HighlightText
$shieldLabel.AutoSize = $true
$shieldLabel.Location = New-Object System.Drawing.Point(12, 8)
$headerPanel.Controls.Add($shieldLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Administrator Privileges Granted"
$titleLabel.ForeColor = [System.Drawing.SystemColors]::HighlightText
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(52, 14)
$headerPanel.Controls.Add($titleLabel)

$bodyLabel = New-Object System.Windows.Forms.Label
$bodyLabel.Text = "You have been granted temporary administrator privileges."
$bodyLabel.AutoSize = $false
$bodyLabel.Size = New-Object System.Drawing.Size(470, 30)
$bodyLabel.Location = New-Object System.Drawing.Point(20, 72)
$bodyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($bodyLabel)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.Text = "A launcher named 'Run-Elevated-Installer.bat' has been placed on your desktop. Double-click it to open the Elevated Application Launcher, where you can browse to and run installers with admin rights.`r`n`r`nYou will be prompted for your Windows password.`r`n`r`nWhen you are finished, you can checkin your Britive profile."
$detailLabel.AutoSize = $false
$detailLabel.Size = New-Object System.Drawing.Size(470, 130)
$detailLabel.Location = New-Object System.Drawing.Point(20, 105)
$form.Controls.Add($detailLabel)

$okButton = New-Object System.Windows.Forms.Button
$okButton.Text = "OK"
$okButton.Size = New-Object System.Drawing.Size(100, 36)
$okButton.Location = New-Object System.Drawing.Point(390, 252)
$okButton.BackColor = [System.Drawing.SystemColors]::Highlight
$okButton.ForeColor = [System.Drawing.SystemColors]::HighlightText
$okButton.FlatStyle = "Flat"
$okButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
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
        $toastTask = "RTR_ElevToast_$(Get-Random)"
        $toastScript = @'
Add-Type -AssemblyName System.Windows.Forms
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Shield
$n.BalloonTipIcon = "Info"
$n.BalloonTipTitle = "Admin Privileges Granted"
$n.BalloonTipText = "Temporary admin access is enabled. Use the 'Run-Elevated-Installer' shortcut on your desktop."
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
    Write-Output "WARNING: No interactive session found for '$samName'; skipping user notification."
}

# --- Step 6: Write the elevated GUI launcher to the user's desktop ---
$guiScriptPath = Join-Path $desktopDir 'ElevatedInstaller.ps1'
$launcherPath  = Join-Path $desktopDir 'Run-Elevated-Installer.bat'

# GUI script (single-quoted here-string: no expansion, written verbatim)
$guiScriptContent = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide the PowerShell console window (type defined before use)
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("Kernel32.dll")]
public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
'
$consolePtr = [Console.Window]::GetConsoleWindow()
[void][Console.Window]::ShowWindow($consolePtr, 0)

$form = New-Object System.Windows.Forms.Form
$form.Text = "Elevated Application Launcher - Administrator"
$form.Size = New-Object System.Drawing.Size(600, 380)
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(20, 100)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.SystemColors]::Control
$form.ForeColor = [System.Drawing.SystemColors]::ControlText
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.TopMost = $false

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 60
$headerPanel.BackColor = [System.Drawing.SystemColors]::Highlight
$form.Controls.Add($headerPanel)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = "Elevated Application Launcher"
$headerLabel.ForeColor = [System.Drawing.SystemColors]::HighlightText
$headerLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$headerLabel.AutoSize = $false
$headerLabel.Size = New-Object System.Drawing.Size(580, 30)
$headerLabel.Location = New-Object System.Drawing.Point(5, 5)
$headerPanel.Controls.Add($headerLabel)

$subHeaderLabel = New-Object System.Windows.Forms.Label
$subHeaderLabel.Text = "Running with Administrator privileges"
$subHeaderLabel.ForeColor = [System.Drawing.SystemColors]::HighlightText
$subHeaderLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$subHeaderLabel.AutoSize = $false
$subHeaderLabel.Size = New-Object System.Drawing.Size(580, 20)
$subHeaderLabel.Location = New-Object System.Drawing.Point(5, 33)
$headerPanel.Controls.Add($subHeaderLabel)

$instructionLabel = New-Object System.Windows.Forms.Label
$instructionLabel.Text = "Browse to the installer or executable you want to run with administrator privileges:"
$instructionLabel.AutoSize = $false
$instructionLabel.Size = New-Object System.Drawing.Size(560, 20)
$instructionLabel.Location = New-Object System.Drawing.Point(15, 75)
$form.Controls.Add($instructionLabel)

$pathTextBox = New-Object System.Windows.Forms.TextBox
$pathTextBox.Size = New-Object System.Drawing.Size(440, 25)
$pathTextBox.Location = New-Object System.Drawing.Point(15, 105)
$pathTextBox.ReadOnly = $true
$pathTextBox.BackColor = [System.Drawing.SystemColors]::Window
$form.Controls.Add($pathTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = "Browse..."
$browseButton.Size = New-Object System.Drawing.Size(100, 25)
$browseButton.Location = New-Object System.Drawing.Point(465, 105)
$browseButton.BackColor = [System.Drawing.SystemColors]::ButtonFace
$browseButton.FlatStyle = "System"
$form.Controls.Add($browseButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ""
$statusLabel.AutoSize = $false
$statusLabel.Size = New-Object System.Drawing.Size(560, 40)
$statusLabel.Location = New-Object System.Drawing.Point(15, 190)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
$form.Controls.Add($statusLabel)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run as Administrator"
$runButton.Size = New-Object System.Drawing.Size(170, 35)
$runButton.Location = New-Object System.Drawing.Point(15, 145)
$runButton.BackColor = [System.Drawing.SystemColors]::Highlight
$runButton.ForeColor = [System.Drawing.SystemColors]::HighlightText
$runButton.FlatStyle = "Flat"
$runButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$runButton.Enabled = $false
$form.Controls.Add($runButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Size = New-Object System.Drawing.Size(100, 35)
$closeButton.Location = New-Object System.Drawing.Point(465, 145)
$closeButton.BackColor = [System.Drawing.SystemColors]::ButtonFace
$closeButton.FlatStyle = "System"
$form.Controls.Add($closeButton)

$historyLabel = New-Object System.Windows.Forms.Label
$historyLabel.Text = "Execution history:"
$historyLabel.AutoSize = $false
$historyLabel.Size = New-Object System.Drawing.Size(560, 18)
$historyLabel.Location = New-Object System.Drawing.Point(15, 240)
$historyLabel.ForeColor = [System.Drawing.SystemColors]::GrayText
$form.Controls.Add($historyLabel)

$historyListBox = New-Object System.Windows.Forms.ListBox
$historyListBox.Size = New-Object System.Drawing.Size(555, 80)
$historyListBox.Location = New-Object System.Drawing.Point(15, 260)
$historyListBox.BackColor = [System.Drawing.SystemColors]::Window
$historyListBox.BorderStyle = "FixedSingle"
$form.Controls.Add($historyListBox)

$browseButton.Add_Click({
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Title = "Select an installer or executable"
    $openFileDialog.Filter = "Executables (*.exe;*.msi;*.bat;*.cmd;*.ps1)|*.exe;*.msi;*.bat;*.cmd;*.ps1|All files (*.*)|*.*"
    $openFileDialog.InitialDirectory = "C:\Users\$env:USERNAME\Downloads"
    if ($openFileDialog.ShowDialog() -eq "OK") {
        $pathTextBox.Text = $openFileDialog.FileName
        $runButton.Enabled = $true
        $statusLabel.Text = ""
    }
})

$runButton.Add_Click({
    $selectedFile = $pathTextBox.Text
    if (-not $selectedFile -or -not (Test-Path $selectedFile)) {
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        $statusLabel.Text = "ERROR: File not found. Browse to a valid file."
        return
    }
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $statusLabel.Text = "Launching: $selectedFile ..."
    $form.Refresh()
    try {
        $extension = [System.IO.Path]::GetExtension($selectedFile).ToLower()
        switch ($extension) {
            ".msi" { Start-Process "msiexec.exe" -ArgumentList "/i `"$selectedFile`"" -Verb RunAs }
            ".ps1" { Start-Process "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$selectedFile`"" -Verb RunAs }
            default { Start-Process -FilePath $selectedFile -Verb RunAs }
        }
        $timestamp = Get-Date -Format "HH:mm:ss"
        $historyListBox.Items.Add("[$timestamp] OK - $selectedFile")
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
        $statusLabel.Text = "Launched. Run another or close this window."
        $pathTextBox.Text = ""
        $runButton.Enabled = $false
    }
    catch {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $historyListBox.Items.Add("[$timestamp] FAILED - $selectedFile")
        $statusLabel.ForeColor = [System.Drawing.Color]::Red
        $statusLabel.Text = "ERROR: Failed to launch. $_"
    }
})

$closeButton.Add_Click({ $form.Close() })

[System.Windows.Forms.Application]::Run($form)
'@

try {
    $guiScriptContent | Out-File -FilePath $guiScriptPath -Encoding ASCII -Force
    Write-Output "GUI script written: $guiScriptPath"
}
catch {
    Write-Output "ERROR: Could not write GUI script to desktop. $_"
    exit 1
}

# Batch launcher (double-quoted here-string: $qualified and $guiScriptPath expand).
# runas forces a fresh logon so the new Administrators membership is in the token,
# then the inner Start-Process -Verb RunAs performs the UAC elevation.
$launcherContent = @"
@echo off
echo ============================================================
echo  ELEVATED APPLICATION LAUNCHER
echo ============================================================
echo.
echo A window will open where you can browse to an installer or
echo application and run it with administrator privileges.
echo.
echo You will be prompted for your Windows password.
echo.
echo ============================================================
echo.
runas /user:$qualified "powershell.exe -Command Start-Process powershell.exe -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -WindowStyle Hidden -File \"$guiScriptPath\"'"
echo.
echo If the window did not appear, run this file again.
echo.
pause
"@

try {
    $launcherContent | Out-File -FilePath $launcherPath -Encoding ASCII -Force
    Write-Output "Batch launcher written: $launcherPath"
}
catch {
    Write-Output "ERROR: Could not write batch launcher to desktop. $_"
    exit 1
}

# --- Result ---
Write-Output ""
Write-Output "============================================================"
Write-Output "DONE. '$qualified' is now a local Administrator."
Write-Output "Desktop files placed for the user:"
Write-Output "  1. Run-Elevated-Installer.bat  (user double-clicks this)"
Write-Output "  2. ElevatedInstaller.ps1       (GUI, launched by the .bat)"
Write-Output ""
Write-Output "Reminder: this grants STANDING local admin. There is no automatic"
Write-Output "revocation. Remove with: Remove-LocalGroupMember -Group Administrators"
Write-Output "-Member '$qualified'  (or run a time-boxed JIT variant instead)."
Write-Output "============================================================"

exit 0