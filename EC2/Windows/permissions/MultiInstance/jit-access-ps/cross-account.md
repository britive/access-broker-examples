# Cross-Account Access for JIT Admin via SSM

This document explains the **IAM role architecture**, **trust relationships**, and **permissions** required to support cross-account execution of SSM documents for temporary Windows access via a centralized PowerShell script.

---

## 🏗️ Architecture Overview

This automation enables a script in **Account A** (Broker Account) to:

* **Assume a role in Account B** (Target EC2 Account)
* **Execute SSM documents** (`AddLocalAdminADUser`, `RemoveLocalADUser`) on EC2 instances based on tag filters
* Grant or revoke temporary AD-based local admin access

---

## 🔐 Roles and Trust Relationships

### 1. **IAM Role in Account B (Target Account)**

#### Name

`cross-account-ec2-ssm-access` (or similar)

#### Purpose

Allows the automation script (in Account A) to assume it and use temporary credentials to:

* Query EC2 instance metadata via AWS CLI
* Send commands via SSM to Windows EC2 instances

#### Trust Policy (Who can assume the role?)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT_A_ID>:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": { }
    }
  ]
}
```

#### Permissions Policy

(Option 1)

* With AWS Managed Policies, attach following policy to the role:
  * AmazonEC2ReadOnlyAccess
  * AmazonSSMFullAccess

(Option 2)
Attach a policy granting access to:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ssm:SendCommand",
        "ssm:GetCommandInvocation"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand"
      ],
      "Resource": [
        "arn:aws:ec2:<REGION>:<ACCOUNT_B_ID>:instance/*",
        "arn:aws:ssm:<REGION>::document/AddLocalAdminADUser",
        "arn:aws:ssm:<REGION>::document/RemoveLocalADUser"
      ]
    }
  ]
}
```

---

### 2. **IAM Role in Account A (Automation Account)**

#### Name

`AutomationRole`

#### Purpose

Runs the PowerShell script and assumes the role in Account B.

#### Permissions Policy

This role needs `sts:AssumeRole` permissions similar to the following:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::<ACCOUNT_B_ID>:role/cross-account-ec2-ssm-access",
      "Condition": { }
    }
  ]
}
```

When the Access broker is running on an EC2 instance add the following policy to the role attached to the EC2 instance:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Resource": "arn:aws:iam::<ACCOUNT_B_ID>:role/cross-account-ec2-ssm-access"
        }
    ]
}
```

---

## 🔄 Script Flow

1. **Broker runs PowerShell script** in Account A
2. Script assumes `JITAssumeRole` in Account B using `Use-STSRole`
3. Retrieves EC2 instances matching `JIT_TAGS` tag filter
4. Sends SSM command (either `AddLocalAdminADUser` or `RemoveLocalADUser`) to matched instances
5. The SSM document executes on the remote Windows host to grant/revoke admin access

---

## 📦 Required SSM Documents

Create the following custom SSM documents in Account B:

* `AddLocalAdminADUser` [Windows/permissions/AddADUser/AddLocalAdminADUser.json]
* `RemoveLocalADUser`  [Windows/permissions/AddADUser/RemoveLocalADUser.json]

These documents:

* Accept a `username` parameter
* Use PowerShell to add/remove the specified AD user to/from the local Administrators group

> ✅ Make sure these documents are set to **`Shared` or `Public`** if used across accounts, or allow access in the automation role policy.

---

## ✅ Requirements

* ✅ AWS CLI v2 installed and in system `PATH`
* ✅ `JIT_TAGS`, `USER`, `DOMAIN`, `REGION`, `ASSUME_ROLE_ARN`, `JIT_ACTION` environment variables set
* ✅ Cross-account trust and permission setup complete
* ✅ SSM documents deployed in the target account

---

## 🧪 Test and Verify

You can test using:

```powershell
$env:JIT_TAGS='{"Project": "AppX"}'
$env:USER='john.doe@example.com'
$env:DOMAIN='AD\'
$env:REGION='us-east-1'
$env:ASSUME_ROLE_ARN='arn:aws:iam::<ACCOUNT_B_ID>:role/cross-account-ec2-ssm-access'
$env:JIT_ACTION='checkout'  # or 'checkin'
```

Then run the script to validate access and permissions.

---
