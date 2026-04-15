# temp-rdp-bridge

Checkout / checkin scripts for JIT RDP access via the **Britive Bridge platform**.

On checkout, a temporary local Windows user is created with a random password. The
password is passed through to Bridge so the RDP proxy can authenticate on the user's
behalf — the user receives a browser-accessible URL and never sees the credential.
On checkin, the Bridge session is terminated and the Windows user is deleted.

---

## Files

| File                     | Purpose                                                |
|--------------------------|--------------------------------------------------------|
| `checkout_rdp_bridge.sh` | Create temp Windows user + register Bridge RDP session |
| `checkin_rdp_bridge.sh`  | Terminate Bridge session + delete temp Windows user    |

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
| --- | --- |
| `BRITIVE_USER_EMAIL` | Britive user email — local part becomes the Windows username |
| `TRX` | Britive transaction ID for this checkout |
| `TARGET_HOST` | Hostname or IP of the RDP target |
| `BRIDGE_URL` | Public base URL of the Bridge (e.g. `https://bridge.example.com`) — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |

### Optional (with defaults)

| Variable | Default | Description |
| --- | --- | --- |
| `TARGET_PORT` | `3389` | RDP port on the target |
| `BRITIVE_FIRST_NAME` | _(empty)_ | User's first name — used for the Windows display name |
| `BRITIVE_LAST_NAME` | _(empty)_ | User's last name — used for the Windows display name |
| `PROVISION_HOST` | `TARGET_HOST` | Override if the provisioning host differs from the RDP target |
| `PROVISION_TRANSPORT` | `winrm` | Remote execution transport: `winrm` or `ssh` |
| `PROVISION_USER` | `Administrator` | Privileged account used to create/delete the temp user |
| `PROVISION_PASSWORD` | _(empty)_ | Password for `PROVISION_USER` — **required for WinRM** |
| `PROVISION_PORT` | `5985` / `5986` / `22` | WinRM HTTP / WinRM HTTPS / SSH port (auto-selected by transport) |
| `PROVISION_KEY` | `/home/bridge/.ssh/id_ed25519` | SSH private key file — SSH transport only |
| `PROVISION_KEY_PEM` | _(empty)_ | Inline PEM key content (preferred over `PROVISION_KEY`; see below) |
| `WINRM_NO_SSL` | `1` | Set to `0` to use WinRM HTTPS on port 5986 instead of HTTP 5985 |
| `LOCAL_GROUP` | `Remote Desktop Users` | Comma-separated local groups to add the temp user to — e.g. `Remote Desktop Users,Administrators` |
| `BROKER_API` | `/opt/britive-broker/scripts/bridge.sh` | Path to the Bridge CLI |

> **Display name:** If `BRITIVE_FIRST_NAME` and `BRITIVE_LAST_NAME` are both set,
> the Windows account's full name is `First Last` (e.g. "Palak Chheda").
> Otherwise it falls back to the email local part (e.g. "palak.chheda").

---

## How It Works

### Checkout (`checkout_rdp_bridge.sh`)

1. Derives a Windows-safe username from `BRITIVE_USER_EMAIL`: strips the `@domain`,
   lowercases, removes non-alphanumeric characters, and caps at 20 characters
   (the Windows SAM account name limit). Prepends `brg` if the result starts with a digit.
2. Sets the display name (FullName) from `BRITIVE_FIRST_NAME` + `BRITIVE_LAST_NAME`,
   falling back to the email local part.
3. Generates a 16-character random password that always satisfies Windows complexity policy
   (uppercase, lowercase, digit, and special character are guaranteed).
4. Connects to the target via WinRM (default) or SSH and runs a PowerShell script that:
   - Creates the local user (or resets the password if the account already exists).
   - Sets the display name so the Windows login shows the user's real identity.
   - Adds the user to each group in `LOCAL_GROUP` (idempotent, comma-separated).
   - Tags the account `Description: bridge:<TRX>` for traceability.
5. Calls `bridge.sh checkout-create` with the RDP payload including the password, so Bridge
   can authenticate the RDP proxy session transparently.
6. Returns:

   ```json
   {"token": "<token>", "url": "https://bridge.example.com/rdp/#token=<token>&transaction_id=<TRX>"}
   ```

### Checkin (`checkin_rdp_bridge.sh`)

1. Calls `bridge.sh checkout-delete` to terminate the active RDP proxy tunnel first —
   this disconnects any live session before the Windows account is removed.
2. Connects to the target and runs a PowerShell script that:
   - Removes the user from each group in `LOCAL_GROUP` (must match the checkout value).
   - Deletes the local user account with `Remove-LocalUser`.
   - Logs warnings (but does not fail) for any already-absent resources.

---

## Target Host Requirements

### WinRM transport (default)

- WinRM must be enabled: `winrm quickconfig` (or via Group Policy on domain machines)
- HTTP listener on port 5985 (default) or HTTPS on 5986 with `WINRM_NO_SSL=0`
- `PROVISION_USER` must have permissions to create and delete local users
  (built-in `Administrator` or a member of the local `Administrators` group)
- For non-built-in admin accounts, `LocalAccountTokenFilterPolicy` must be set to `1`:

  ```powershell
  New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
      -Name "LocalAccountTokenFilterPolicy" -Value 1 -PropertyType DWORD -Force
  ```

- NTLM authentication enabled (default on most Windows Server installs)
- Unencrypted traffic allowed (for HTTP): `winrm set winrm/config/service '@{AllowUnencrypted="true"}'`

### SSH transport (`PROVISION_TRANSPORT=ssh`)

- OpenSSH Server installed and running (available as a Windows optional feature since
  Windows Server 2019 / Windows 10 1809)
- For the built-in `Administrator` account, the broker's public key must be placed in
  `C:\ProgramData\ssh\administrators_authorized_keys` (not `~\.ssh\authorized_keys`),
  with ACLs restricting access to `SYSTEM` and `Administrators` only:

  ```bat
  icacls administrators_authorized_keys /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)"
  ```

- For non-admin `PROVISION_USER` accounts, `~\.ssh\authorized_keys` works as on Linux
- PowerShell 5.1+ must be available as `powershell.exe`

---

## Broker Container Requirements

**WinRM (default):** `python3`, `pywinrm` (`pip install pywinrm`), `bridge.sh` at `BROKER_API` path.

**SSH:** `python3`, `ssh`, `bridge.sh` at `BROKER_API` path.

---

## Verify Prerequisites

Run these commands from inside the broker / Bridge container before deploying the scripts.

### Always required

```sh
python3 --version
/opt/britive-broker/scripts/bridge.sh health
```

### WinRM verification

```sh
python3 -c "import winrm; print('pywinrm OK:', winrm.__version__)" \
  || echo "MISSING — run: pip install pywinrm"

python3 - <<'EOF'
import winrm, sys
host     = "<TARGET_HOST>"
user     = "<PROVISION_USER>"
password = "<PROVISION_PASSWORD>"
port     = 5985                     # use 5986 if WINRM_NO_SSL=0

session = winrm.Session(
    target='http://{}:{}/wsman'.format(host, port),
    auth=(user, password),
    transport='ntlm',
    server_cert_validation='ignore',
)
result = session.run_ps('hostname')
if result.status_code != 0:
    sys.stderr.write(result.std_err.decode('utf-8', 'replace'))
    sys.exit(result.status_code)
print('WinRM OK — target hostname:', result.std_out.decode('utf-8', 'replace').strip())
EOF
```

### SSH verification

```sh
ssh -V

ssh -i /home/bridge/.ssh/id_ed25519 \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    Administrator@<TARGET_HOST> \
    "powershell.exe -NonInteractive -Command \"Write-Output ('SSH+PS OK — ' + \$env:COMPUTERNAME)\""
```

> **Note:** For the built-in `Administrator` account on Windows, the SSH key must be in
> `C:\ProgramData\ssh\administrators_authorized_keys` (not `~\.ssh\authorized_keys`).
> See [Target Host Requirements](#target-host-requirements) for the ACL setup.

---

## Transport Notes

### WinRM (default)

WinRM is the recommended transport for Windows targets. It is already enabled
on most Windows Server domain machines via Group Policy and does not require an
additional OpenSSH installation.

The scripts default to HTTP (port 5985) with `WINRM_NO_SSL=1`. For HTTPS (port 5986),
set `WINRM_NO_SSL=0`. The scripts use `server_cert_validation='ignore'` so a
self-signed certificate is acceptable.

### SSH

SSH transport is available for environments where OpenSSH Server is already deployed
on Windows targets. It requires no Python dependencies beyond `python3` (for encoding
the PowerShell script as UTF-16LE base64 for `-EncodedCommand`).

### `PROVISION_KEY_PEM` (SSH only)

Prefer `PROVISION_KEY_PEM` over `PROVISION_KEY` for the broker private key. The inline
PEM content is written to `/dev/shm` (tmpfs) at runtime and deleted by the exit trap —
it never touches persistent disk. `PROVISION_KEY` (a file path) is the fallback for
bind-mounted key scenarios.

---

## Britive Platform Setup

1. Create a broker pool connected to your Bridge deployment.
2. Create a `Bridge` resource type with an `rdp` permission.
3. Set the following script parameters on the `rdp` permission:

   **Always required:** `TRANSACTION_ID`, `PROTOCOL` (set to `rdp`), `USERNAME`,
   `EXPIRATION`, `BRIDGE_URL`, `TARGET_HOST`

   **Transport:** `PROVISION_TRANSPORT`, `PROVISION_USER`, `PROVISION_PASSWORD`
   (WinRM) or `PROVISION_KEY_PEM` (SSH)

   **Optional:** `TARGET_PORT`, `LOCAL_GROUP`, `WINRM_NO_SSL`,
   `BRITIVE_FIRST_NAME`, `BRITIVE_LAST_NAME`

4. Set the response template to `Bridge Session URL` (uses `{{url}}` from the checkout output).
5. Assign users or tags to the profile policy.
