# Bridge admin access

Checkout / checkin scripts that grant a Britive identity **Bridge administrator
powers for the lifetime of a checkout**, then take them away again.

Unlike every other pattern in this repo, this one provisions nothing on a target
host. There is no temporary account, no key, and no proxied session — the
checkout *is* the grant.

## What an admin can do

A Bridge administrator can create and revoke checkouts, view and live-watch every
session, lock / unlock / force-disconnect sessions, issue and revoke share links,
and install or remove licenses.

Administrator status normally comes from your **identity provider** — an admin
group mapped at login. These scripts are the alternative: a bounded, audited
window granted through the same JIT checkout flow as everything else, so nobody
has to sit in a standing admin group.

## Files

| File | Purpose |
|------|---------|
| `bridge_admin_checkout.sh` | Register a role checkout; return the admin console URL |
| `bridge_admin_checkin.sh`  | Delete the checkout, ending the grant |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TRANSACTION_ID` | Yes | Britive transaction ID for this checkout |
| `ROLE` | Yes | Role to grant — `admin`, or `auditor` for scoped oversight |
| `USERNAME` | Yes | The Britive identity receiving the role |
| `EXPIRATION` | Yes | Grant duration in seconds — **checkout only** |
| `BRIDGE_URL` | Yes | Bridge hostname — **checkout only** |

`ROLE` is a variable rather than a hardcoded `admin` so one pair of scripts can
back both an admin profile and a lower-privilege `auditor` profile. See
[Roles: user, auditor, admin](https://learn.britive.com/bridge/checkouts/roles/)
for what each one carries.

## How It Works

### Checkout

Registers a checkout carrying `role` and `username` and nothing else — no
protocol, no target, no credential:

```json
{
  "transaction_id": "<TRX>",
  "role": "admin",
  "username": "grace@corp",
  "expires_at": 1750000000
}
```

The Bridge authorizes from the user's session plus this active checkout. **There
is no token to hand out** — the returned URL is just where to go:

```json
{ "browser_session": "https://bridge.example.com/user-sessions" }
```

A response template can surface `{{browser_session}}`, matching the key the SSH,
RDP and database bridge patterns emit.

### Checkin

Deletes the checkout, which ends the grant immediately. The user drops back to
whatever role their identity provider gives them.

## Broker Container Requirements

`/opt/britive-broker/scripts/bridge.sh`, which the Bridge image ships as a
symlink to `broker-bridge-api.sh`. Either name works.

## Security Notes

- The grant lives and dies with the transaction. `expires_at` bounds it even if
  checkin never runs.
- Nothing is written to a target host, so a failed checkin cannot leave a
  credential behind — the worst case is an admin grant that persists until
  `expires_at`.
- Scope `ROLE` to `auditor` wherever oversight is enough. An `admin` checkout can
  revoke other people's sessions and manage licenses.
