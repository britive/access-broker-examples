# Britive Broker Service Account — AD Permissions Setup

This document describes the exact Active Directory permissions the Britive
broker service account requires to execute the scripts in this repository.
Follow the principle of least privilege: delegate only the permissions listed
below, scoped to the OUs that contain the accounts and groups the broker manages.

---

## 1. Service Account

Create a dedicated AD user account for the Britive broker service to run under.

| Field                        | Recommended value                          |
|------------------------------|--------------------------------------------|
| **SamAccountName**           | `svc-britive`                              |
| **Location**                 | A dedicated OU, e.g. `OU=ServiceAccounts,DC=contoso,DC=com` |
| **Password never expires**   | Yes                                        |
| **User cannot change password** | Yes                                     |
| **Account is disabled**      | No                                         |

```powershell
New-ADUser `
    -Name            "svc-britive" `
    -SamAccountName  "svc-britive" `
    -UserPrincipalName "svc-britive@contoso.com" `
    -Path            "OU=ServiceAccounts,DC=contoso,DC=com" `
    -AccountPassword (Read-Host -AsSecureString "Password") `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Enabled $true `
    -Description "Britive on-premise broker service account"
```

The Windows Britive Broker service should be configured to **Log on as** this
account in the Services console (`services.msc`) or via:

```powershell
sc.exe config "BritiveBroker" obj= "CONTOSO\svc-britive" password= "<password>"
```

---

## 2. Required Permissions by Script

### 2.1 Read — AD Scan (`scans/ad-scan.ps1`)

Reads all users, groups, group memberships, and domain information.

| Operation | Cmdlet | Default for domain users? |
|-----------|--------|--------------------------|
| Read user objects & attributes | `Get-ADUser -Filter *` | **Yes** — no delegation needed |
| Read group objects | `Get-ADGroup -Filter *` | **Yes** — no delegation needed |
| Read group members | `Get-ADGroupMember` | **Yes** — no delegation needed |
| Read domain info | `Get-ADDomain` | **Yes** — no delegation needed |

> No additional delegation is required for the scan. Any authenticated domain
> user can read standard user and group attributes.

---

### 2.2 Group Membership — Add/Remove (`permissions/add-user-to-group/`, `permissions/add-group-multi/`)

Adds or removes users from groups. Requires **Write** on the `member` attribute
of group objects in the relevant OUs.

**Permission:** Write `member` attribute on group objects.

```powershell
# Substitute the OU DN that contains your managed groups
$groupOU = "OU=ManagedGroups,DC=contoso,DC=com"

dsacls $groupOU /I:S /G "CONTOSO\svc-britive:WP;member;group"
```

---

### 2.3 User Creation — First-time "-a" / Prefixed Accounts (`permissions/add-group-multi/`, `permissions/rotate-a-account/`)

Creates a new user object when one does not yet exist.

**Permission:** Create child `user` objects in the target OU.

```powershell
# Substitute the OU DN where new accounts will be created
$userOU = "OU=ManagedAccounts,DC=contoso,DC=com"

dsacls $userOU /I:T /G "CONTOSO\svc-britive:CC;user"
```

---

### 2.4 Password Reset — All Rotate Scripts

All rotate and checkout scripts use `Set-ADAccountPassword -Reset`.
This requires the **Reset Password** control access right — it is distinct
from a normal user password change and must be explicitly delegated.

**Permission:** Reset Password control access right on user objects.

```powershell
$userOU = "OU=ManagedAccounts,DC=contoso,DC=com"

dsacls $userOU /I:S /G "CONTOSO\svc-britive:CA;Reset Password;user"
```

---

### 2.5 Enable Account — Checkout Scripts (`permissions/rotate-a-account/`, `permissions/rotate-svc-account/`)

`Enable-ADAccount` writes the `userAccountControl` attribute.

**Permission:** Write `userAccountControl` on user objects.

```powershell
$userOU = "OU=ManagedAccounts,DC=contoso,DC=com"

dsacls $userOU /I:S /G "CONTOSO\svc-britive:WP;userAccountControl;user"
```

---

### 2.6 Unlock Account + Disable Force-Change-Password (`rotate/rotate-ad-account.ps1`, `rotate/rotate-ad-service-account.ps1`)

- `Unlock-ADAccount` writes the `lockoutTime` attribute.
- `Set-ADUser -ChangePasswordAtLogon $false` writes the `pwdLastSet` attribute.

**Permissions:** Write `lockoutTime` and `pwdLastSet` on user objects.

```powershell
$userOU = "OU=ManagedAccounts,DC=contoso,DC=com"

dsacls $userOU /I:S /G "CONTOSO\svc-britive:WP;lockoutTime;user"
dsacls $userOU /I:S /G "CONTOSO\svc-britive:WP;pwdLastSet;user"
```

---

### 2.7 Remote Service Credential Update (`rotate/rotate-ad-service-account.ps1`)

This script connects to a remote Windows server via PSRemoting (WinRM) and
reconfigures + restarts a Windows service using `sc.exe`. No extra AD
permissions are required, but the broker service account needs **local
administrative rights on each target server**.

**Grant local admin on each target server:**

```powershell
# Run this ON THE TARGET SERVER (or via GPO)
$targetServer = "EC2AMAZ-7S7IJ04"

Invoke-Command -ComputerName $targetServer -ScriptBlock {
    Add-LocalGroupMember -Group "Administrators" -Member "CONTOSO\svc-britive"
}
```

Alternatively, use a **Group Policy** to add `CONTOSO\svc-britive` to the
`Administrators` local group on all servers the broker is expected to manage
(`Computer Configuration > Preferences > Local Users and Groups`).

**WinRM must also be enabled on each target server:**

```powershell
# Run on each target server, or push via GPO
Enable-PSRemoting -Force
```

---

## 3. Complete Delegation Script

Apply all delegations in a single pass. Adjust the OU DNs to match your environment.

```powershell
# ============================================================
# Britive Broker Service Account — AD Delegation Script
# Run as a Domain Admin on a Domain Controller or from a
# machine with RSAT installed.
# ============================================================

$brokerAccount = "CONTOSO\svc-britive"

# OU that contains the user accounts the broker manages
$userOU = "OU=ManagedAccounts,DC=contoso,DC=com"

# OU that contains the groups the broker manages
$groupOU = "OU=ManagedGroups,DC=contoso,DC=com"

Write-Host "Delegating permissions for: $brokerAccount"

# -- User object creation
dsacls $userOU /I:T /G "$brokerAccount`:CC;user"
Write-Host "  [OK] Create user objects in $userOU"

# -- Password reset
dsacls $userOU /I:S /G "$brokerAccount`:CA;Reset Password;user"
Write-Host "  [OK] Reset password on users in $userOU"

# -- Enable / disable accounts
dsacls $userOU /I:S /G "$brokerAccount`:WP;userAccountControl;user"
Write-Host "  [OK] Write userAccountControl on users in $userOU"

# -- Unlock accounts
dsacls $userOU /I:S /G "$brokerAccount`:WP;lockoutTime;user"
Write-Host "  [OK] Write lockoutTime on users in $userOU"

# -- Disable force-change-password at logon
dsacls $userOU /I:S /G "$brokerAccount`:WP;pwdLastSet;user"
Write-Host "  [OK] Write pwdLastSet on users in $userOU"

# -- Add / remove group members
dsacls $groupOU /I:S /G "$brokerAccount`:WP;member;group"
Write-Host "  [OK] Write member attribute on groups in $groupOU"

Write-Host ""
Write-Host "Done. Verify with: dsacls `"$userOU`""
```

---

## 4. Local Machine Requirements (Broker Host)

### 4.1 RSAT Active Directory Module

The machine running the Britive broker must have the **RSAT Active Directory
PowerShell module** installed. On Windows Server:

```powershell
Install-WindowsFeature -Name "RSAT-AD-PowerShell"
```

On Windows 10/11:

```powershell
Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
```

### 4.2 Broker Install Directory Permissions

The broker writes downloaded scripts and scan output into its install directory.
The service account **must have Full Control** over the broker install directory:

```text
C:\Program Files (x86)\Britive Inc\Britive Broker\
```

This is required because:

- Scripts are downloaded to `cache\` and executed from there
- Scan output files are written to `cache\` by the broker process
- Log files are written to the install directory at runtime

**Option A — Grant the service account local admin on the broker host** (simplest):

```powershell
Add-LocalGroupMember -Group "Administrators" -Member "CONTOSO\svc-britive"
```

**Option B — Grant Full Control on the install directory only** (least privilege):

```powershell
$installDir = "C:\Program Files (x86)\Britive Inc\Britive Broker"
$acl = Get-Acl $installDir

$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "CONTOSO\svc-britive",
    "FullControl",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl -Path $installDir -AclObject $acl

Write-Host "Full Control granted to CONTOSO\svc-britive on $installDir"
```

> **Note:** Option B is preferred in environments where granting local admin
> is not acceptable. The service account still needs to be able to **log on
> as a service** (granted automatically when configured via `sc.exe config` or
> `services.msc`).

---

## 5. Permission Summary Table

| Script | Create User | Reset Password | Enable/Disable | Unlock | Disable Force-PW-Change | Write Group Member | Remote Local Admin |
|--------|:-----------:|:--------------:|:--------------:|:------:|:------------------------:|:------------------:|:------------------:|
| `scans/ad-scan.ps1` | | | | | | | |
| `permissions/add-user-to-group/checkout.ps1` | | | | | | ✓ | |
| `permissions/add-user-to-group/checkin.ps1` | | | | | | ✓ | |
| `permissions/add-group-multi/group-multi-checkout.ps1` | ✓ | | | | | ✓ | |
| `permissions/rotate-a-account/rotate-a-account-checkout.ps1` | ✓ | ✓ | ✓ | | | | |
| `permissions/rotate-a-account/rotate-a-account-checkout-passphrase.ps1` | ✓ | ✓ | ✓ | | | | |
| `permissions/rotate-svc-account/rotate-svc-account-checkout.ps1` | | ✓ | ✓ | | | | |
| `rotate/rotate-ad-account.ps1` | | ✓ | ✓ | ✓ | ✓ | | |
| `rotate/rotate-ad-service-account.ps1` | | ✓ | ✓ | ✓ | ✓ | | ✓ |

---

## 6. Official Documentation

**[Installing Broker on Windows — Britive Docs](https://docs.britive.com/docs/installing-broker-on-windows)**

The Britive on-premise broker is a lightweight Windows service that bridges
the Britive cloud platform with internal AD resources. Key points from the
official installation guide:

- The broker is installed under `C:\Program Files (x86)\Britive Inc\Britive Broker\`
  and runs as a Windows service.
- Configuration is stored in `broker-config.yml` inside the install directory.
  This file specifies the broker pool token, execution environment, and script paths.
- For PowerShell-based integrations (such as this AD example), the
  `execution_environment` setting in `broker-config.yml` must be set to
  `powershell.exe -File` so scripts are invoked correctly.
- The broker communicates outbound to the Britive cloud over HTTPS (port 443)
  and AWS IoT MQTT — no inbound firewall ports are required on the broker host.
- At startup the broker calls a bootstrap endpoint to register with its broker
  pool, then subscribes to an MQTT topic to receive checkout/checkin
  instructions from the platform in real time.

> Refer to the official guide for the full installer walkthrough, YAML
> configuration reference, and broker pool token setup:
> <https://docs.britive.com/docs/installing-broker-on-windows>
