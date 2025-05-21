# Just-In-Time EC2 Access Script (PowerShell)

This script grants or revokes temporary admin access to Windows EC2 instances using AWS SSM and tag-based filters.

## 📦 Requirements

- PowerShell 5.1+ or PowerShell Core
- AWS Tools for PowerShell:
  ```powershell
  Install-Module -Name AWS.Tools.EC2, AWS.Tools.SSM -Scope CurrentUser
  ```
- AWS credentials configured via environment, profile, or session
- SSM Documents:
  - `AddLocalAdminADUser`
  - `RemoveLocalADUser`

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

## 🚀 Usage

```powershell
$env:JIT_TAGS = '{"Environment":"Dev","App":"MyApp"}'
$env:USER = "ad\jdoe"
$env:JIT_ACTION = "checkout"  # or "checkin"
.\jit-access.ps1
```

## 📝 Notes

- Make sure the EC2 instances are managed by SSM and the IAM role allows SSM document execution for the machine running the Access Broker.
