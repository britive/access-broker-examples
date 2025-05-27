# Just-In-Time EC2 Access Script (PowerShell)

This script grants or revokes temporary admin access to Windows EC2 instances using AWS SSM and tag-based filters.

---

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

```powershell
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

---

## 📥 Installing AWS CLI v2 (Windows)

### ✅ Step 1: Download the AWS CLI v2 Installer

Visit the official AWS download page:

👉 [https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-windows.html](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-windows.html)

Or download directly:

> [Download AWS CLI v2 MSI installer for Windows (64-bit)](https://awscli.amazonaws.com/AWSCLIV2.msi)

### ✅ Step 2: Run the Installer

1. Double-click the downloaded `.msi` file (`AWSCLIV2.msi`).
2. Follow the prompts to complete the installation.
3. Accept defaults unless you have specific requirements.

### ✅ Step 3: Verify Installation

Open **PowerShell** and run:

```powershell
aws --version
```

You should see output similar to:

```powershell
aws-cli/2.15.21 Python/3.11.5 Windows/10 exe/AMD64 prompt/off
```

If you see a "command not found" error, continue to the next step to manually add it to your system `PATH`.

### 🔧 Step 4 (Optional): Add AWS CLI to System PATH

If `aws` is not recognized, add the AWS CLI executable directory manually:

#### a. Find the install location (default)

```text
C:\Program Files\Amazon\AWSCLIV2\
```

#### b. Add to PATH

1. Open Start → search for **"Environment Variables"**.
2. Click **Environment Variables…**
3. Under **System variables**, find and select `Path` → click **Edit…**
4. Click **New**, then paste:

    ```text
    C:\Program Files\Amazon\AWSCLIV2\
    ```

5. Click **OK** to apply changes.
6. Close and re-open PowerShell.


### ✅ Step 5: Re-run Version Check

```powershell
aws --version
```

You should now see version output confirming successful installation.


### ✅ (Optional) Enable Auto-Completion in PowerShell

To enable tab-completion for AWS CLI:

```powershell
Install-Module -Name AWS.Tools.Installer -Force -Scope CurrentUser
```

Or just rely on CLI help:

```powershell
aws help
aws ec2 describe-instances help
```

---

## 📝 Notes

* Make sure the EC2 instances are managed by SSM and the IAM role allows SSM document execution for the machine running the Access Broker.
