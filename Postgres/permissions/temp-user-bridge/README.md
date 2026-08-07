# temp-user-bridge (PostgreSQL)

Checkout / checkin scripts for JIT RDS / Aurora PostgreSQL access **proxied
through the Britive Bridge (v2)**.

On checkout, a temporary PostgreSQL role is created with a random password, and
a `postgres` database checkout is registered with the Bridge carrying the
caller's **bridge credential** (`native_auth=bridge_credentials`). The user
connects with their **local `psql` client (or DBeaver, pgAdmin, etc.) on their
workstation**, pointed at the Bridge's native PostgreSQL listener, and
authenticates with the **Bridge Username/Password set on their Britive profile**
(Manage Account → Bridge Attributes) — the broker injects these to the script as
`BRIDGE_AUTH_*` env vars. The real PostgreSQL credentials never leave the
broker/Bridge, and the session is fully brokered and recorded.

On checkin, the role is dropped and the Bridge checkout is deleted, which
immediately terminates any active session.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_postgres_bridge.sh` | Create temp role + register Bridge session |
| `checkin_postgres_bridge.sh`  | Drop temp role + terminate Bridge session |

---

## How the user connects

The checkout returns everything needed for a native connection:

```
psql "host=<bridge-host> port=5432 user=<email>%<pg-endpoint> dbname=<db-name>"
```

- **Host / port** — `BRIDGE_URL:NATIVE_PORT`, the Bridge's native PostgreSQL
  listener, not the database. One NLB fronts both the web tier and every native
  listener, so the browser session and the native client use the same host.
- **Username** — `<email>%<target-host>` where `<email>` is the user's Britive
  identity (`user`). The Bridge matches this against the checkout's owner to
  route the session — it must equal the checkout owner / SSO identity, **not**
  the profile "Bridge Username" field.
- **Password** — the Bridge Password from the user's Britive profile
  (`BRIDGE_AUTH_PASSWORD`), registered on the checkout; the user types it at the
  psql password prompt.
- **Browser** — `{{browser_session}}` opens the in-browser SQL window
  (`https://<bridge-host>/db/#transaction_id=<TRX>`).

GUI clients (DBeaver, pgAdmin) work the same way — same host, port, username
format, and password.

---

## Two things PostgreSQL forces that MySQL does not

- **No `host` variable.** A MySQL account is `'user'@'host'`; a PostgreSQL role
  is cluster-wide and host restrictions live in `pg_hba.conf`, so there is
  nothing to pass.
- **Grants are issued twice** — once at database level and once inside the
  target database's `public` schema. From PostgreSQL 15 the public schema no
  longer grants `CREATE` to `PUBLIC`, so a database-level `GRANT` alone leaves
  the role able to connect but unable to create anything.

The role name is lowercased when derived from the email local part: an unquoted
identifier folds to lower case in PostgreSQL, so creating `JDoe` and then
referring to `jdoe` would otherwise miss.

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `user` | Requesting user's email — local part becomes the PostgreSQL role name |
| `dburl` | RDS / Aurora PostgreSQL endpoint hostname |
| `secret` | AWS Secrets Manager secret ID holding admin `{username, password}` |
| `TRX` | Britive transaction ID for this checkout |
| `BRIDGE_URL` | Bridge hostname — one NLB serves both browser and native sessions, e.g. `bridge.example.com` — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `BRIDGE_AUTH_PASSWORD` | Bridge password from the profile; broker-injected. Typed at the psql password prompt |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_NAME` | `postgres` | Database the grants apply to |
| `DB_PORT` | `5432` | PostgreSQL port on the target |
| `NATIVE_PORT` | `5432` | Port of the Bridge's native PostgreSQL listener |
| `TARGET_TLS` | `true` | TLS from the Bridge to the target |
| `DB_CA_CERT` | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables `sslmode=verify-full` on the admin connection. Without it the connection is encrypted but the chain is not verified (`sslmode=require`) |
| `AWS_REGION` | `us-west-2` | Secrets Manager region |
| `BROKER_API` | `/opt/britive-broker/scripts/broker-bridge-api.sh` | Path to the Bridge API helper CLI |

---

## How It Works

### Checkout (`checkout_postgres_bridge.sh`)

1. Derives the role name from the user's email (local part, sanitized, lowercased).
2. Generates a random password for the temp role — **only the Bridge ever sees it**.
3. Fetches admin credentials from Secrets Manager, creates the role, and grants
   at both database and `public` schema level.
4. Registers a `postgres` checkout with the Bridge
   (`broker-bridge-api.sh checkout-create`) containing the target endpoint, temp
   role credentials, `target_tls`, and the bridge credential
   (`native_auth=bridge_credentials` + `bridge_auth_password`). If registration
   fails, the role is dropped.
5. Returns JSON in the standard Bridge checkout schema — the same keys as the
   Linux SSH, Windows RDP, MySQL and SQL Server bridge checkouts, so one
   response template covers all of them:

   ```json
   {
     "BRIDGE_URL": "bridge.example.com",
     "command": "psql \"host=bridge.example.com port=5432 user=alice@corp%mydb.cluster-abc.us-west-2.rds.amazonaws.com dbname=postgres\"",
     "auth_method": "password",
     "bridge_username": "alice@corp%mydb.cluster-abc.us-west-2.rds.amazonaws.com",
     "bridge_port": "5432",
     "target_username": "alice",
     "browser_session": "https://bridge.example.com/db/#transaction_id=<TRX>"
   }
   ```

### Checkin (`checkin_postgres_bridge.sh`)

1. Drops the temp role, reassigning or dropping anything it owns first.
2. Deletes the Bridge checkout (`broker-bridge-api.sh checkout-delete <TRX>`),
   revoking the proxy credential and terminating any active session immediately.

---

## Bridge Requirements

Native PostgreSQL mode must be enabled on the Bridge (it is off by default):

- `native.enabled: true`
- `native.listen: :5432` (or your chosen `NATIVE_PORT`)
- optionally `browser.enabled: true` for the in-browser SQL window

See the [Bridge database protocol docs](https://learn.britive.com/bridge/protocols/databases/)
and the [checkout payload reference](https://learn.britive.com/bridge/checkouts/payload/).

The Bridge must reach the PostgreSQL endpoint on `DB_PORT`, and users must reach
the Bridge on `NATIVE_PORT`.

---

## Broker Container Requirements

- `psql` client, `aws` CLI (with Secrets Manager read access), `jq`
- `broker-bridge-api.sh` at `BROKER_API` (default `/opt/britive-broker/scripts/broker-bridge-api.sh`)

---

## Security Notes

- The temp role's password is generated at checkout, passed to the Bridge as
  `target_password`, and never returned to the user.
- The bridge password (`BRIDGE_AUTH_PASSWORD`) comes from the user's Britive
  profile via the broker and is registered on the checkout as
  `bridge_auth_password`; the checkout dies with the transaction on checkin or
  expiry (`expires_at`).
- `target_tls=true` keeps the Bridge → PostgreSQL hop encrypted; the client →
  Bridge hop is handled by the Bridge's own TLS.
