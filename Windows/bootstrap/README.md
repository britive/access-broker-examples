# Windows Bootstrap Scripts

Bootstrap scripts used by the Britive Access Broker on Windows to discover domain-joined
servers and generate the resource list that Britive uses for access management.

---

## Resource Generator (Primary)

These two files work together and should be deployed as the primary option for resource discovery.

### `windows-resource-generator.ps1`

Queries Active Directory for all enabled, domain-joined Windows Server computers and outputs
a JSON array in the Britive Access Broker resource format.

**JSON output format:**
```json
[
  {
    "type": "Windows",
    "name": "server01.contoso.com",
    "labels": {
      "OS": ["Windows"],
      "Environment": ["Production"]
    },
    "parameters": {
      "hostname": "server01.contoso.com"
    }
  }
]
```

- `name` is the server FQDN (`DNSHostName` from AD, falls back to the SAM account name)
- `Environment` is inferred from the server hostname (e.g. `prod`, `dev`, `qa`, `stg`) and then
  the OU canonical path; defaults to `Development` if no pattern matches

**Parameters:**

| Parameter        | Required | Description |
|-----------------|----------|-------------|
| `-OUPath`        | No       | Restrict the AD search to a specific OU distinguished name. Searches the entire domain if omitted. |
| `-IncludeOffline` | No      | Include servers that do not respond to a ping. By default offline servers are skipped. |

**Run manually:**
```powershell
# All domain servers (online only)
.\windows-resource-generator.ps1

# Scoped to a specific OU
.\windows-resource-generator.ps1 -OUPath "OU=Servers,DC=contoso,DC=com"

# Include offline servers
.\windows-resource-generator.ps1 -IncludeOffline
```

**Requirements:**
- Windows Server with Active Directory PowerShell module (RSAT)
- Domain-joined machine with read access to AD computer objects

---

### `windows-resource-generator.bat`

A wrapper that invokes `windows-resource-generator.ps1` via `powershell.exe`. This is the
file to reference in the broker config — the broker executes `.bat` files directly, whereas
`.ps1` files require PowerShell to be invoked explicitly.

Uses `%~dp0` to resolve the `.ps1` path relative to the `.bat` file, so both files must be
in the same directory.

**Broker config (`config.yml`):**
```yaml
config:
  version: 2
  bootstrap:
    tenant_subdomain: <your-tenant>
    authentication_token: <your-token>
    resources_generator: C:\Britive\windows-resource-generator.bat
```

> **Note:** Place the bat file at a path with no spaces (e.g. `C:\Britive\`) to avoid
> issues with Java's `ProcessBuilder` splitting the path on spaces.

**Run manually (to verify output before deploying):**
```cmd
windows-resource-generator.bat
```
```powershell
& "C:\Britive\windows-resource-generator.bat"
```

---

## Legacy / Static Scripts

These scripts are retained for reference but are superseded by the AD-based scripts above.

### `resources.bat`

Static script that echoes a single hardcoded JSON resource entry. Useful for initial
broker setup and connectivity testing before AD discovery is configured.

### `resources.ps1`

Wrapper that calls `Get-ADServersMetadata.ps1`. Retained for backwards compatibility.

### `Get-ADServersMetadata.ps1`

Earlier version of the AD resource discovery script. Outputs a richer metadata format
(including `dnsHostName`, `ipAddresses`, `distinguishedName`, etc.) that does not match
the standard Britive Access Broker resource schema. Use `windows-resource-generator.ps1`
instead.

---

## Other Scripts

### `agent-name-generate.bat`

Outputs the broker agent name. Used by the broker during registration.

---

## Troubleshooting

**No output from the resource generator:**
1. Run `windows-resource-generator.bat` manually in cmd or PowerShell to see errors directly
2. Add `-IncludeOffline` to the bat file temporarily to rule out connectivity filtering
3. Verify the AD module is installed: `Get-Module -ListAvailable -Name ActiveDirectory`
4. Confirm the service account running the broker has read access to AD computer objects

**YAML parse errors in `config.yml`:**
- Do not use backslashes in double-quoted YAML strings — use a path without spaces so
  no quoting is needed, or use single quotes: `'C:\path\to\file'`
- Ensure consistent 4-space indentation under `bootstrap:`

**`%1 is not a valid Win32 application` error:**
- The broker cannot execute `.ps1` files directly. Always point `resources_generator`
  to the `.bat` wrapper, not the `.ps1` file.
