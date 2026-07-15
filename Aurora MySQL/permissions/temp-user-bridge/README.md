# temp-user-bridge

Checkout / checkin scripts for JIT Aurora MySQL access **proxied through the Britive Bridge**.

On checkout, a temporary MySQL user is created with a random password, and a
`mysql` database checkout is registered with the Bridge carrying the caller's
**bridge credential** (`native_auth=bridge_credentials`). The user connects with
their **local `mysql` client (or DBeaver, etc.) on their workstation**, pointed
at the Bridge's native MySQL listener, and authenticates with the **Bridge
Username/Password set on their Britive profile** (Manage Account → Bridge
Attributes) — the broker injects these to the script as `BRIDGE_AUTH_*` env
vars. The real MySQL credentials never leave the broker/Bridge — the session is
fully brokered and recorded.

On checkin, the MySQL user is dropped and the Bridge checkout is deleted, which
immediately terminates any active session.

---

## Files

| File | Purpose |
|------|---------|
| `checkout_mysql_bridge.sh` | Create temp MySQL user + register Bridge session |
| `checkin_mysql_bridge.sh`  | Drop temp MySQL user + terminate Bridge session |

---

## How the user connects

The checkout returns everything needed for a native connection:

```
mysql -h <native-host> -P 3306 -u '<email>%<aurora-endpoint>' -p <db-name>
```

- **Host / port** — `native_host:NATIVE_PORT`, the Bridge's native MySQL
  listener, not the database. `native_host` defaults to the web host
  (`BRIDGE_URL`); set `NATIVE_HOST` when web (ALB) and native (NLB) endpoints
  differ.
- **Username** — `<email>%<target-host>` where `<email>` is the user's Britive
  identity (`user`). The Bridge matches this against the checkout's owner to
  route the session — it must equal the checkout owner / SSO identity, **not**
  the profile "Bridge Username" field.
- **Password** — the Bridge Password from the user's Britive profile
  (`BRIDGE_AUTH_PASSWORD`), registered on the checkout; the user types it at the
  mysql password prompt.

GUI clients (DBeaver, MySQL Workbench) work the same way — same host, port,
username format, and password.

---

## Environment Variables

### Required (set by Britive)

| Variable | Description |
|----------|-------------|
| `user` | Requesting user's email — local part becomes the MySQL username |
| `host` | MySQL host part for `'user'@'host'` (typically `%`) |
| `dburl` | RDS / Aurora endpoint hostname |
| `secret` | AWS Secrets Manager secret ID holding admin `{username, password}` |
| `TRX` | Britive transaction ID for this checkout |
| `BRIDGE_URL` | Bridge web hostname (browser sessions), e.g. `bridge.example.com` — **checkout only** |
| `EXPIRATION` | Session duration in seconds — **checkout only** |
| `BRIDGE_AUTH_PASSWORD` | Bridge password from the profile; broker-injected. Typed at the mysql password prompt. The native login username is the user's email (`user`), not a separate bridge username |

### Optional (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `NATIVE_HOST` | `BRIDGE_URL` host | Hostname native mysql clients connect to, when it differs from the web host (web on ALB, native listeners on NLB) |
| `DB_NAME` | `systemdb` | Database the `GRANT ALL` applies to |
| `DB_PORT` | `3306` | MySQL port on the Aurora endpoint |
| `NATIVE_PORT` | `3306` | Port of the Bridge's native MySQL listener |
| `TARGET_TLS` | `true` | TLS from the Bridge to Aurora (recommended for RDS/Aurora) |
| `DB_CA_CERT` | — | Path to the [RDS CA bundle](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem) on the broker; enables server cert verification for the admin connection. Without it the connection is encrypted but the chain is not verified (needed because MariaDB 11.4+ clients verify by default and reject the RDS CA) |
| `AWS_REGION` | `us-west-2` | Secrets Manager region |
| `BROKER_API` | `/opt/britive-broker/scripts/broker-bridge-api.sh` | Path to the Bridge API helper CLI |

---

## How It Works

### Checkout (`checkout_mysql_bridge.sh`)

1. Derives the MySQL username from the user's email (local part, alphanumeric only).
2. Generates a random password for the temp MySQL user — **only the Bridge ever sees it**.
3. Fetches admin credentials from Secrets Manager and runs
   `CREATE USER` + `GRANT ALL ON <DB_NAME>.*`.
4. Registers a `mysql` checkout with the Bridge
   (`broker-bridge-api.sh checkout-create`) containing the target endpoint,
   temp user credentials, `target_tls`, and the bridge credential
   (`native_auth=bridge_credentials` + `bridge_auth_password`). If registration
   fails, the temp user is dropped.
5. Returns JSON in the standard Bridge checkout schema (same keys as the
   Linux SSH and Windows RDP bridge checkouts, so one response template
   covers all of them):

   ```json
   {
     "BRIDGE_URL": "bridge.example.com",
     "native_host": "bridge.example.com",
     "command": "mysql -h bridge.example.com -P 3306 -u 'alice@corp%mydb.cluster-abc.us-west-2.rds.amazonaws.com' -p systemdb",
     "auth_method": "password",
     "bridge_username": "alice@corp%mydb.cluster-abc.us-west-2.rds.amazonaws.com",
     "bridge_port": "3306",
     "target_username": "alicecorp",
     "browser_session": "https://bridge.example.com/db/#transaction_id=<TRX>"
   }
   ```

   A response template can surface `{{command}}` and `{{bridge_username}}`
   directly; the password prompt takes the Bridge Password from the user's
   Britive profile. `{{browser_session}}` opens the in-browser SQL window when
   browser mode is enabled on the Bridge.

### Checkin (`checkin_mysql_bridge.sh`)

1. Drops the temp MySQL user (`DROP USER IF EXISTS`).
2. Deletes the Bridge checkout (`broker-bridge-api.sh checkout-delete <TRX>`),
   revoking the proxy credential and terminating any active session immediately.

---

## Bridge Requirements

Native MySQL mode must be enabled on the Bridge (it is off by default). In the
Bridge database protocol configuration, enable the MySQL native listener:

- `native.enabled: true`
- `native.listen: :3306` (or your chosen `NATIVE_PORT`)
- optionally `browser.enabled: true` for the in-browser SQL window

See the [Bridge database protocol docs](https://learn.britive.com/bridge/protocols/databases/)
for the exact configuration format, and the
[checkout payload reference](https://learn.britive.com/bridge/checkouts/payload/)
for all database checkout fields.

The Bridge must have network reachability to the Aurora endpoint on `DB_PORT`,
and users must be able to reach the Bridge on `NATIVE_PORT`.

---

## Broker Container Requirements

- `mysql` client, `aws` CLI (with Secrets Manager read access), `jq`
- `broker-bridge-api.sh` at `BROKER_API` path (default `/opt/britive-broker/scripts/broker-bridge-api.sh`)

---

## Security Notes

- The temp MySQL user's password is generated at checkout, passed to the Bridge
  as `target_password`, and never returned to the user.
- The bridge password (`BRIDGE_AUTH_PASSWORD`) comes from the user's Britive
  profile via the broker and is registered on the checkout as
  `bridge_auth_password`; the checkout dies with the transaction on checkin or
  expiry (`expires_at`).
- `target_tls=true` keeps the Bridge → Aurora hop encrypted; the client →
  Bridge hop is handled by the Bridge's own TLS.
