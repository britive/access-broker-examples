# temp-user-bridge (SQL Server)

Checkout / checkin scripts for JIT RDS SQL Server access **proxied through the
Britive Bridge (v2)**.

On checkout, a temporary SQL Server **LOGIN** (server scope) is created with a
random password, plus a matching **USER** in the target database added to a
database role. A `mssql` database checkout is then registered with the Bridge
carrying the caller's **bridge credential**
(`native_auth=bridge_credentials`). The user connects with their **local
`sqlcmd` client (or SSMS, Azure Data Studio, DBeaver) on their workstation**,
pointed at the Bridge's native SQL Server listener, and authenticates with the
**Bridge Username/Password set on their Britive profile** (Manage Account →
Bridge Attributes) — the broker injects these to the script as `BRIDGE_AUTH_*`
env vars. The real SQL Server credentials never leave the broker/Bridge.

On checkin, the database USER and the server LOGIN are dropped and the Bridge
checkout is deleted, which immediately terminates any active session.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_mssql_bridge.sh` | Create temp LOGIN + USER, register Bridge session |
| `checkin_mssql_bridge.sh`  | Drop USER + LOGIN, terminate Bridge session |

---

## Read this before you rely on the native command

The v2 ECS stack registers NLB target groups for **ssh, rdp, mysql and postgres
only** — ECS caps a service at five load-balancer registrations. MSSQL is
enabled inside the container but has **no native listener** in that stack, so
the emitted `command` only works once you add an NLB listener and target group
for port 1433 yourself.

**The `browser_session` URL works either way.** On the default v2 ECS
deployment, that is the supported path.

---

## How the user connects

The checkout returns everything needed for a native connection:

```
sqlcmd -S tcp:<bridge-host>,1433 -U '<email>%<mssql-endpoint>' -d <db-name> -N -C
```

- **Host / port** — `BRIDGE_URL:NATIVE_PORT`, the Bridge's native SQL Server
  listener, not the database. One NLB fronts both the web tier and every native
  listener, so the browser session and the native client use the same host.
- **Username** — `<email>%<target-host>` where `<email>` is the user's Britive
  identity (`user`). The Bridge matches this against the checkout's owner to
  route the session — it must equal the checkout owner / SSO identity, **not**
  the profile "Bridge Username" field.
- **Password** — the Bridge Password from the user's Britive profile
  (`BRIDGE_AUTH_PASSWORD`), registered on the checkout; the user types it at the
  sqlcmd password prompt.
- **Browser** — `{{browser_session}}` opens the in-browser SQL window
  (`https://<bridge-host>/db/#transaction_id=<TRX>`).

---

## How SQL Server differs from the MySQL flow

- **No `host` variable.** There is no `'user'@'host'` in SQL Server — access
  scope is the **LOGIN** (server level) plus a **USER** (per database). Use
  `DB_ROLE` to control what that user can do.
- **Credentials go through `SQLCMDPASSWORD`**, not a defaults file, so they
  never appear in the process list.

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `user` | Requesting user's email — local part becomes the SQL Server login name |
| `dburl` | RDS SQL Server endpoint hostname |
| `secret` | AWS Secrets Manager secret ID holding admin `{username, password}` |
| `TRX` | Britive transaction ID for this checkout |
| `BRIDGE_URL` | Bridge hostname — one NLB serves both browser and native sessions, e.g. `bridge.example.com` — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `BRIDGE_AUTH_PASSWORD` | Bridge password from the profile; broker-injected. Typed at the sqlcmd password prompt |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_NAME` | `systemdb` | Database the temp USER is created in |
| `DB_ROLE` | `db_owner` | Database role the temp USER joins. Use `db_datareader` / `db_datawriter` for least privilege |
| `DB_PORT` | `1433` | SQL Server port on the target |
| `NATIVE_PORT` | `1433` | Port of the Bridge's native SQL Server listener |
| `TARGET_TLS` | `true` | TLS from the Bridge to SQL Server |
| `DB_TRUST_SERVER_CERT` | `false` | `true` skips server-cert chain validation on the **admin** connection (`sqlcmd -C`). The default encrypts (`-N`) **and** verifies against the system trust store, which already carries the RDS global bundle. There is no `DB_CA_CERT` here — go-sqlcmd has no CA-file flag and uses the system store instead |
| `AWS_REGION` | `us-west-2` | Secrets Manager region |
| `BROKER_API` | `/opt/britive-broker/scripts/broker-bridge-api.sh` | Path to the Bridge API helper CLI |

---

## How It Works

### Checkout (`checkout_mssql_bridge.sh`)

1. Derives the login name from the user's email (local part, restricted to
   `[A-Za-z0-9]` so it is always safe inside `[brackets]`).
2. Generates a random password for the temp login — **only the Bridge ever sees it**.
3. Fetches admin credentials from Secrets Manager, then creates the server
   LOGIN, the database USER, and adds the USER to `DB_ROLE`.
4. Registers a `mssql` checkout with the Bridge
   (`broker-bridge-api.sh checkout-create`) containing the target endpoint, temp
   credentials, `target_tls`, and the bridge credential
   (`native_auth=bridge_credentials` + `bridge_auth_password`). If registration
   fails, the login and user are dropped.
5. Returns JSON in the standard Bridge checkout schema — the same keys as the
   Linux SSH, Windows RDP, MySQL and PostgreSQL bridge checkouts, so one
   response template covers all of them:

   ```json
   {
     "BRIDGE_URL": "bridge.example.com",
     "command": "sqlcmd -S tcp:bridge.example.com,1433 -U 'alice@corp%mydb.abc.us-west-2.rds.amazonaws.com' -d systemdb -N -C",
     "auth_method": "password",
     "bridge_username": "alice@corp%mydb.abc.us-west-2.rds.amazonaws.com",
     "bridge_port": "1433",
     "target_username": "alice",
     "browser_session": "https://bridge.example.com/db/#transaction_id=<TRX>"
   }
   ```

### Checkin (`checkin_mssql_bridge.sh`)

1. Drops the database USER, then the server LOGIN.
2. Deletes the Bridge checkout (`broker-bridge-api.sh checkout-delete <TRX>`),
   revoking the proxy credential and terminating any active session immediately.

---

## Bridge Requirements

Native SQL Server mode must be enabled on the Bridge (it is off by default):

- `native.enabled: true`
- `native.listen: :1433` (or your chosen `NATIVE_PORT`)
- optionally `browser.enabled: true` for the in-browser SQL window

See the [Bridge database protocol docs](https://learn.britive.com/bridge/protocols/databases/)
and the [checkout payload reference](https://learn.britive.com/bridge/checkouts/payload/).

The Bridge must reach the SQL Server endpoint on `DB_PORT`. For native client
access, users must reach the Bridge on `NATIVE_PORT` — see the caveat above.

---

## Broker Container Requirements

- `sqlcmd` (go-sqlcmd), `aws` CLI (with Secrets Manager read access), `jq`
- `broker-bridge-api.sh` at `BROKER_API` (default `/opt/britive-broker/scripts/broker-bridge-api.sh`)

Microsoft's `mssql-tools` are glibc + amd64 only and will not run on the
musl/ARM64 Bridge image, which is why go-sqlcmd is used.

---

## Security Notes

- The temp login's password is generated at checkout, passed to the Bridge as
  `target_password`, and never returned to the user.
- The bridge password (`BRIDGE_AUTH_PASSWORD`) comes from the user's Britive
  profile via the broker and is registered on the checkout as
  `bridge_auth_password`; the checkout dies with the transaction on checkin or
  expiry (`expires_at`).
- `target_tls=true` keeps the Bridge → SQL Server hop encrypted; the client →
  Bridge hop is handled by the Bridge's own TLS.
