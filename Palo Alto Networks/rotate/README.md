# PAN-OS – Administrator Password Rotation (break-glass)

Sets a new password on an **existing** firewall or Panorama administrator — typically the built-in `admin` — and commits only the broker's own change. Role, authentication profile and every other attribute are untouched (only the `phash` node is set).

| Script | Purpose |
|---|---|
| `rotate-panos-admin.py` | Generate (or accept) a new password, `request password-hash`, `set` the `phash`, `commit partial`, return the secret |

Imports `../permissions/jit-admin/panos_api.py`; keep both directories together.

Wire the script as **both** `checkout_script` and `checkin_script`: checkout rotates and returns the secret to the user; checkin rotates again and returns it to the broker for the Secrets Store.

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `PANOS_HOST` | Yes | Firewall or Panorama |
| `PANOS_API_USER` / `PANOS_API_PASSWORD` (or `PANOS_API_KEY`) | Yes | Broker's administrator (Secrets Store) |
| `PANOS_TARGET_USER` | Yes | Administrator to rotate, e.g. `admin`. May be the API user itself; the API key obtained before the change remains valid for the run |
| `PANOS_NEW_PASSWORD` | No | Supply only when another system owns the value |
| `PANOS_PASSWORD_LENGTH` | No | Default `20` |
| `PANOS_COMMIT_TIMEOUT`, `PANOS_PORT`, `PANOS_VERIFY_TLS`, `PANOS_CA_BUNDLE` | No | Connection options |

## Output

```json
{"login":"admin","hostname":"fw-edge-01","password":"…","web_url":"https://fw-edge-01/"}
```

## Britive Broker Config Example

```yaml
resource_types:
  panos:
    break-glass-admin:
      max_supported_version: local
      execution_environment: python3 <BRITIVE_PERMISSION_SCRIPT>
      checkout_script: /opt/britive-broker/scripts/Palo Alto Networks/rotate/rotate-panos-admin.py
      checkin_script:  /opt/britive-broker/scripts/Palo Alto Networks/rotate/rotate-panos-admin.py
```

## Notes

- Rotation never creates accounts; a missing `PANOS_TARGET_USER` exits `1` before any change.
- Existing API keys for the rotated administrator are invalidated when its password changes (PAN-OS ties keys to the credential). If the break-glass admin is also used for API automation, rotate that automation's key afterwards or give it its own account.
- HA peers synchronize administrators; rotate against the active peer only.
- Panorama's `admin` and each firewall's `admin` are separate objects; register each as its own resource.
