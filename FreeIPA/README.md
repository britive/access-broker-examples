# FreeIPA Group Membership Management with PowerShell

This PowerShell script allows you to manage user membership in FreeIPA groups using the [Manage-FreeIPA](https://github.com/MS-LUF/Manage-FreeIPA) module. It supports connecting to a FreeIPA server, checking whether a user and group exist, and adding or removing a user from a group.

## Features

- Connects to FreeIPA using provided credentials.
- The script expect the user and group information from the checkout/in request.
- Checks if the target user and group exist. before processing the action.
- The action is passed as an attribute to the string from the Britive Profile. Allowing us to use single script for both checkout and checkin.
- Adds or removes the user from the specified group.
- Uses try/catch blocks for robust error handling. Exits with appropriate codes and error messages.

## Requirements

- PowerShell 5.1 or higher (Windows or cross-platform with PowerShell Core)
- [Manage-FreeIPA PowerShell module](https://github.com/MS-LUF/Manage-FreeIPA)

## Installation

First, clone or install the [Manage-FreeIPA](https://github.com/MS-LUF/Manage-FreeIPA) module and make sure it's available in your `$env:PSModulePath`.

### Parameters

| Name         | Type     | Description                                             | Source                    |
|--------------|----------|---------------------------------------------------------| ---------------------     |
| `Server`     | `string` | The FreeIPA server hostname or IP address.              | Local or Resource config  |
| `Username`   | `string` | Admin username for FreeIPA authentication.              | Local or Resource config  |
| `Password`   | `string` | Admin password.                                         | Local or vault            |
| `User`       | `string` | The user to add/remove from the group.                  | Profile - Dynamic         |
| `Group`      | `string` | The group to manage membership in.                      | Profile - Dynamic         |
| `Action`     | `string` | Either `Checkout` or `Checkin`.                         | Profile - Dynamic         |

## Exit Codes

| Code | Description                             |
|------|-----------------------------------------|
| 0    | Success                                 |
| 1    | General error                           |
| 2    | User not found or login failed          |
| 3    | Group not found                         |
| 4    | Failed to add/remove user from group    |


## Notes

- Make sure the FreeIPA server is accessible from the machine running the script.
- This script is intended for administrative actions with appropriate privileges.
