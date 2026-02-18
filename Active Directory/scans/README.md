## Active Directory Scan

This directory contains a PowerShell script that scans Active Directory for users, groups, and group memberships and outputs the data as JSON for downstream processing by the Britive Resource Manager.

### Script: `ad-scan.ps1`

Connects to Active Directory, retrieves all user and group objects along with direct group membership details, and writes the results to a structured JSON file at the path specified by the Britive broker.

#### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `BROKER_INJECTED_SCAN_OUTPUT_PATH` | Yes | Full file path where the scan JSON output will be written. Injected by the Britive broker at runtime. |

#### How It Works

1. Validates the `BROKER_INJECTED_SCAN_OUTPUT_PATH` environment variable is set (fails immediately if not).
2. Creates the output directory if it does not exist.
3. Imports the `ActiveDirectory` PowerShell module.
4. Retrieves domain information for metadata.
5. Scans all AD users and captures: email, first/last name, SamAccountName, UPN, and DistinguishedName.
6. Scans all AD groups and captures direct (non-recursive) user members.
7. Writes the JSON output to the broker-specified path.
8. On failure, writes a minimal JSON with the error details so the broker can report the failure back to the platform.

#### Identity Resolution

- **User `id`** uses `SamAccountName` (e.g., `jdoe`). Short values that fit within database column limits.
- **Group `id`** uses the group `Name`.
- **Group `members`** arrays contain user `SamAccountName` values, matching the identity `id` field so that `attribute_resolution.group_membership = "id"` resolves correctly.
- `DistinguishedName` and `UserPrincipalName` are stored in `attributes` for reference.

#### Output Schema

The script produces a JSON file with the following structure:

- **`data.identities`** - All AD user objects with attributes: `email`, `first_name`, `last_name`, `samaccountname`, `user_principal_name`, `distinguished_name`.
- **`data.groups`** - All AD group objects with their direct member lists (referencing identity `id` values) and attributes: `samaccountname`, `distinguished_name`.
- **`data.permissions`** - Empty array (AD does not have separate permission/role objects).
- **`data.permission_mapping`** - Empty array (user-to-group assignments are captured in `groups.members`).
- **`metadata`** - Includes `resource_id` (domain DN), `resource_type`, `scan_time`, `scan_details`, `scan_errors`, and `attribute_resolution`.

#### Fail-Fast Behavior

- `$ErrorActionPreference = 'Stop'` ensures any non-terminating error is promoted to a terminating error.
- Missing `BROKER_INJECTED_SCAN_OUTPUT_PATH` causes an immediate failure before any AD queries run.
- Output directory is validated and created before the scan begins.
- The top-level `try/catch` writes a valid error JSON so the broker always receives a parseable response.

#### Prerequisites

- Windows PowerShell 5.1 or later
- RSAT Active Directory module installed (see [parent README](../README.md) for installation instructions)
- Appropriate permissions to read AD user and group objects
