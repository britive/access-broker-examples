# FreeIPA Group Membership Management with PowerShell

This PowerShell script allows you to manage user membership in FreeIPA groups using the [Manage-FreeIPA](https://github.com/MS-LUF/Manage-FreeIPA) module. It supports connecting to a FreeIPA server, checking whether a user and group exist, and adding or removing a user from a group.

## Features

- Connects to FreeIPA using provided credentials.
- Checks if the target user and group exist.
- Adds or removes the user from the specified group.
- Uses try/catch blocks for robust error handling.
- Exits with appropriate codes and error messages.

## Requirements

- PowerShell 5.1 or higher (Windows or cross-platform with PowerShell Core)
- [Manage-FreeIPA PowerShell module](https://github.com/MS-LUF/Manage-FreeIPA)

## Installation

First, clone or install the [Manage-FreeIPA](https://github.com/MS-LUF/Manage-FreeIPA) module and make sure it's available in your `$env:PSModulePath`.

## Usage

```powershell
.\Manage-FreeIPAGroup.ps1 `
    -Server "ipa.example.com" `
    -Username "admin" `
    -Password "YourSecretPassword" `
    -TargetUser "jdoe" `
    -TargetGroup "developers" `
    -Action Add
```

### Parameters

| Name         | Type     | Description                                            |
|--------------|----------|--------------------------------------------------------|
| `Server`     | `string` | The FreeIPA server hostname or IP address.            |
| `Username`   | `string` | Admin username for FreeIPA authentication.            |
| `Password`   | `string` | Admin password.                                        |
| `TargetUser` | `string` | The user to add/remove from the group.                |
| `TargetGroup`| `string` | The group to manage membership in.                    |
| `Action`     | `string` | Either `Add` or `Remove`.                             |

## Exit Codes

| Code | Description                             |
|------|-----------------------------------------|
| 0    | Success                                 |
| 1    | General error                           |
| 2    | User not found or login failed          |
| 3    | Group not found                         |
| 4    | Failed to add/remove user from group    |

## Examples

### Add user `jdoe` to group `developers`

```powershell
.\Manage-FreeIPAGroup.ps1 -Server ipa.example.com -Username admin -Password 'secret' `
    -TargetUser jdoe -TargetGroup developers -Action Add
```

### Remove user `jdoe` from group `developers`

```powershell
.\Manage-FreeIPAGroup.ps1 -Server ipa.example.com -Username admin -Password 'secret' `
    -TargetUser jdoe -TargetGroup developers -Action Remove
```

## Notes

- Make sure the FreeIPA server is accessible from the machine running the script.
- This script is intended for administrative actions with appropriate privileges.
