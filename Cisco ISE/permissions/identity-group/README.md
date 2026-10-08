# Cisco ISE – Identity Group Membership (AAA-driven elevation)

Adds an **existing ISE internal user** to an ISE identity group at checkout and removes them at checkin, through the ERS API. ISE policy does the rest: a Device Administration authorization rule maps the group to a TACACS+ shell profile (privilege 15) and command set, or a Network Access rule maps it to a RADIUS authorization profile.

The group is empty at rest. The user authenticates with their own ISE password; only the authorization changes.

| Script | Purpose |
|---|---|
| `checkout.py` | Add the user to `ISE_TARGET_GROUP`; idempotent if already a member |
| `checkin.py` | Remove the user from `ISE_TARGET_GROUP`; idempotent |
| `ise_ers.py` | Shared ERS helper (imported by both) — keep it in the same directory |

Users that live in **Active Directory** are not touched by these scripts; use the `Active Directory/` group-membership scripts and point the ISE rule at the AD group instead.

---

## ISE setup

1. **Identity group**: *Administration > Identity Management > Groups > User Identity Groups* → `NET-ADMIN-15`. Leave it empty.
2. **Device Admin policy**: *Work Centers > Device Administration > Device Admin Policy Sets > Authorization Policy*:

   | Rule | Condition | Shell profile | Command set |
   |---|---|---|---|
   | NetAdmin-JIT | IdentityGroup equals `NET-ADMIN-15` | `priv-15` (default privilege 15) | `PermitAll` |
   | NetOps-Default | IdentityGroup equals `NET-OPS` | `priv-1` | `ShowOnly` |

3. **ERS**: *Administration > System > Settings > API Settings* → enable ERS. Create an admin in the **ERS Admin** group for the broker.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `ISE_HOST` | Yes | Primary Admin Node |
| `ISE_ERS_USER` / `ISE_ERS_PASSWORD` | Yes | ERS admin (Secrets Store) |
| `BRITIVE_USER_EMAIL` | Yes | Requesting identity, Britive-injected |
| `ISE_TARGET_GROUP` | Yes | Identity group name, e.g. `NET-ADMIN-15` |
| `ISE_USERNAME` | No | ISE internal username if it differs from the email local part |
| `ISE_ERS_PORT` | No | Default `9060` |
| `ISE_VERIFY_TLS` / `ISE_CA_BUNDLE` | No | TLS verification (on by default) |

## Output

```json
{"login":"alice","group":"NET-ADMIN-15","ise_host":"ise-pan.example.com","groups":["<ops-group-id>","<admin-group-id>"],"note":"Authenticate with your own ISE password; the group grants the elevated authorization."}
```

Checkin prints nothing.

---

## Britive Broker Config Example

```yaml
resource_types:
  cisco-ise:
    net-admin-15:
      max_supported_version: local
      execution_environment: python3 <BRITIVE_PERMISSION_SCRIPT>
      checkout_script: /opt/britive-broker/scripts/Cisco ISE/permissions/identity-group/checkout.py
      checkin_script:  /opt/britive-broker/scripts/Cisco ISE/permissions/identity-group/checkin.py
```

`ISE_HOST` comes from the resource; `ISE_TARGET_GROUP` from the permission variables; the ERS credential from the Secrets Store. One permission per group gives you `net-admin-15`, `net-ops-config`, and so on.

---

## Behavior notes

- `checkout.py` refuses to run for a user that does not exist in ISE's internal store. It elevates; it never creates identities.
- The full user object is sent back on the ERS `PUT` with only `identityGroups` changed, so enabled state, email and custom attributes are preserved.
- Removal at checkin does not terminate open TACACS+ sessions. Front the devices with Britive Bridge; the session closes at expiry.
- ISE caches nothing for internal users; the next TACACS+ authorization sees the new membership immediately.
