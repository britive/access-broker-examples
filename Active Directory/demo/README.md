## Demo / Examples

This directory contains setup scripts that create sample environments for testing the Britive broker password rotation scripts. Each script builds a working demo on a domain-joined Windows Server 2022 machine.

> **Note:** These scripts are for testing and demonstration purposes only. They create AD accounts with placeholder passwords and simple service configurations. Do not use these in production.

---

### `setup-iis-demo.ps1`

Sets up an IIS web application with a custom Application Pool running under an AD service account. Use this to test [`rotate-ad-iis-account.ps1`](../rotate/rotate-ad-iis-account.ps1).

#### What It Creates

| Resource | Name | Details |
|---|---|---|
| AD service account | `svc-iis-demo` | Enabled, password never expires |
| IIS Application Pool | `DemoAppPool` | Runs as `DOMAIN\svc-iis-demo` |
| IIS Website | `DemoWebSite` | Bound to port 8080, serves a basic HTML page |
| Site content | `C:\inetpub\demosite\` | Contains `index.html` |

#### Usage

```powershell
# Run as Administrator on a domain-joined Windows Server 2022
.\setup-iis-demo.ps1
```

After setup, test the rotation:

```powershell
$env:AD_TARGET_USER    = "svc-iis-demo"
$env:AD_NEW_PASSWORD   = "NewP@ssw0rd!2024"
$env:AD_TARGET_SERVER  = "YOUR-SERVER-NAME"
$env:AD_APPPOOL_NAME   = "DemoAppPool"
..\rotate\rotate-ad-iis-account.ps1
```

Verify by browsing to `http://localhost:8080` — if the page loads, the app pool is running with valid credentials.

#### What Gets Installed

- IIS Web Server role (`Web-Server`)
- IIS scripting tools (`Web-Scripting-Tools`)
- RSAT Active Directory module (must be pre-installed)

---

### `setup-windows-service-demo.ps1`

Sets up a sample Windows service running under an AD service account. Use this to test [`rotate-ad-service-account.ps1`](../rotate/rotate-ad-service-account.ps1).

#### What It Creates

| Resource | Name | Details |
|---|---|---|
| AD service account | `svc-demo-app` | Enabled, password never expires, granted "Log on as a service" |
| Windows service | `BritiveDemoService` | Runs a PowerShell sleep loop as `DOMAIN\svc-demo-app` |
| Service script | `C:\BritiveDemo\service.ps1` | Minimal script that logs a heartbeat every 60 seconds |
| Log file | `C:\BritiveDemo\service.log` | Written by the service while running |

#### Usage

```powershell
# Run as Administrator on a domain-joined Windows Server 2022
.\setup-windows-service-demo.ps1
```

After setup, test the rotation:

```powershell
$env:AD_TARGET_USER    = "svc-demo-app"
$env:AD_NEW_PASSWORD   = "NewP@ssw0rd!2024"
$env:AD_TARGET_SERVER  = "YOUR-SERVER-NAME"
$env:AD_SERVICE_NAME   = "BritiveDemoService"
..\rotate\rotate-ad-service-account.ps1
```

Verify by checking the service status:

```powershell
Get-Service -Name BritiveDemoService
```

And checking the log file for continued heartbeats after rotation:

```powershell
Get-Content C:\BritiveDemo\service.log -Tail 5
```

#### Prerequisites

- Windows Server 2022 (domain-joined)
- Run as Administrator
- RSAT Active Directory module installed (see [parent README](../README.md) for installation instructions)
