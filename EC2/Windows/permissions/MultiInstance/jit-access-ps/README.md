# Just-In-Time EC2 Access Script (PowerShell)

This script grants or revokes temporary admin access to Windows EC2 instances using AWS SSM and tag-based filters.

## 📦 Requirements

### ✅ Step-by-Step (AllUsers Scope)

1. **Open PowerShell as Administrator**.

2. Run the following commands:

```powershell
# Unregister PSGallery if it exists and is misconfigured
Unregister-PSRepository -Name PSGallery -ErrorAction SilentlyContinue

# Re-register PSGallery using the Default parameter
Register-PSRepository -Default

# Set installation policy to Trusted (for all users)
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Add required AWS Modules
Install-Module AWS.Tools.EC2
Install-Module AWS.Tools.SimpleSystemsManagement

```

Add these modules in the Broker User's Profile
```powershell
Import-Module AWS.Tools.EC2 -ErrorAction Stop
Import-Module AWS.Tools.SimpleSystemsManagement -ErrorAction Stop
```


This registers the PSGallery repository using the default settings and marks it as **Trusted**.

---

### 🧪 Optional: Confirm Scope and Policy

You can confirm that it’s trusted and properly registered for all users:

```powershell
Get-PSRepository -Name PSGallery
```

Expected output:

```
Name        : PSGallery
SourceLocation : https://www.powershellgallery.com/api/v2
InstallationPolicy : Trusted
PackageManagementProvider : NuGet
```

---

### 🧱 FYI: Scope Behavior

PowerShell repository settings are stored in files like:

* For **CurrentUser** scope: `~\AppData\Local\Microsoft\Windows\PowerShell\PowerShellGet\`
* For **AllUsers** scope: `%ProgramData%\Microsoft\Windows\PowerShell\PowerShellGet\`


## ⚙️ Environment Variables

- `JIT_TAGS` – JSON string of tag filters. Example:
  ```json
  {
    "Environment": "Dev",
    "App": "MyApp"
  }
  ```
- `USER` – Username to grant/revoke access for
- `JIT_ACTION` – `checkout` or `checkin` (defaults to `checkout`)


## 📝 Notes

- Make sure the EC2 instances are managed by SSM and the IAM role allows SSM document execution for the machine running the Access Broker.
