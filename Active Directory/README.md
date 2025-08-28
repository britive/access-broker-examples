# Active Directory Access

This folder contains various examples Powershell scripts.
These scripts allow for better access management in Active Directory. The goal here is to secure high privilege access by granting ephemeral access or rotating credentials of powerful user accounts.

To **run Active Directory (AD) cmdlets like `Get-ADUser` or `Add-ADGroupMember` on a Windows machine**, the following prerequisites must be met:

---

### ✅ **Pre-Requisite: Active Directory PowerShell Module Must Be Installed**

To ensure this is configured for **all users**, you can **install the RSAT: Active Directory module** via PowerShell (must be run as Administrator):

#### 🛠 PowerShell Command to Install AD Module (Windows 10/11 or Server 2019/2022):

```powershell
Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
```

---

### 🔍 To Verify Installation (Optional):

```powershell
Get-WindowsCapability -Name RSAT.ActiveDirectory* -Online
```

---

### 🧠 What This Does:

* Installs the **Active Directory module** for Windows PowerShell (`ActiveDirectory`).
* Allows any user (with appropriate permissions) to run `Import-Module ActiveDirectory` and use `Get-ADUser`, `Add-ADGroupMember`, etc.
* Makes the module globally available — no need to manually import for every user session (though `Import-Module` is still commonly used at the start of scripts for safety).

---

### 🧪 Optional: Check if AD module is available before running script

Add this to the top of your script to ensure the module is installed:

```powershell
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "The ActiveDirectory module is not installed. Run the following as admin:`nAdd-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'"
    exit 1
}
```

## Broker Service Permissions 

Broker runs all actions for temporary access privileges in Active Directory (AD) and Windows as the said Service Account. For the use cases to be covered, the service account requires additional permissions on Active Directory as well as Windows services via a Group Policy Object (GPO).
For Active Directory group membership updates:


How to Assign the Permissions (Delegation)
You can use Active Directory Users and Computers (ADUC) to delegate these rights:
1.	Open ADUC and enable Advanced Features (View > Advanced Features).
2.	Right-click the target group (or parent OU if doing this broadly) and select Properties.
3.	Go to the Security tab and click Advanced.
4.	Click Add, then:
o	Select the service account.
o	Set Applies to: This object only.
o	Under Permissions, check:
1.	Read members
2.	Write members
5.	Save and apply changes.
Additionally, to rotate temporary account credentials and to manage user account states, assign User Account management permission at the appropriate OU level.


## Managing User Accounts

## Adding and Removing a user from a group

Scripts located under '/permissions/add-user-to-group'

## Managing users' dedicated Admin Accounts (-a)

### Enable Account and add to group

Scripts located under '/permissions/add-group-a-account'

### Enable and Disable -a Account

Scripts located under '/permissions/disable-a-account'

### Rotate password and state of -a Account

Scripts located under '/permissions/disable-rotate-a-account'

### Rotate password of -a account

Scripts located under '/permissions/rotate-a-account'

## Managing service account credentials

### Rotate Service Account password

Scripts located under '/permissions/rotate-svc-account'
