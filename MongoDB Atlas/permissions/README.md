# MongoDB Atlas JIT Access with Britive

Secure Just-In-Time (JIT) access for MongoDB Atlas using the Britive Access Broker. All scripts follow a Zero Standing Privileges (ZSP) model — elevated access exists only for the duration of a Britive session and is automatically revoked on checkin or timer expiry.

## Security Benefits

- **Zero Standing Privileges** — no permanent elevated database credentials; roles exist only during an active session
- **Just-In-Time Access** — elevation is granted on demand and revoked automatically
- **Audit Trail** — every checkout and checkin is logged in Britive and in the script log file
- **Least Privilege** — each permission type is scoped to the minimum required: database, project, or org level
- **Secret Safety** — credentials are passed via Authorization headers or Digest auth; never logged or exposed in process listings

## Architecture

```text
User Request → Britive Platform → Checkout Script → MongoDB Atlas API → Role Elevated
                                                                              ↓
User Session ←────────────────── Temporary Access Granted ──────────────────
                                                                              ↓
Session End  → Checkin Script  → MongoDB Atlas API → Role Revoked
```

## Permission Types

Four permission types are available, each in its own subdirectory. Choose the type that matches the scope of access needed.

| Directory | Scope | Auth Method | Use Case |
| --------- | ----- | ----------- | -------- |
| [DB Roles](./DB%20Roles/) | Database-level roles | OAuth 2.0 | Grant `dbAdmin`, `readWrite`, etc. on a specific database |
| [Organization Role](./Organization%20Role/) | Org-level roles | OAuth 2.0 | Grant `ORG_READ_ONLY`, `ORG_MEMBER`, etc. across the org |
| [Project Role](./Project%20Role/) | Project-level roles | OAuth 2.0 | Grant `GROUP_READ_ONLY`, `GROUP_OWNER`, etc. within a project |
| [On Premises MongoDB](./On%20Premises%20MongoDB/) | Database-level roles | API Key Digest | Grant `dbAdmin`/`read` on on-premises or standalone MongoDB |

## Prerequisites

- **Britive Platform** access with an Access Broker configured
- **MongoDB Atlas** organization and project access
- **MongoDB Atlas Service Account** with appropriate scope (OAuth2, for DB / Org / Project Role scripts)
  - Or a **MongoDB Atlas API Key pair** (for On Premises scripts)
- `curl` and `jq` installed on the broker host

## Authentication Methods

### OAuth 2.0 (DB Roles, Organization Role, Project Role)

Recommended for all Atlas-native integrations. A Service Account is created in Atlas and granted the minimum required scope. Scripts exchange client credentials for a short-lived token on each execution — no long-lived secrets in the execution environment.

Required Service Account scopes per permission type:

| Permission Type | Required Scope |
| --------------- | -------------- |
| DB Roles | Project Database Access Admin (or Project Owner) |
| Organization Role | Organization Owner |
| Project Role | Project Owner |

### API Key Digest Auth (On Premises MongoDB)

Used where OAuth2 Service Accounts are not available. A public/private API key pair authenticates via HTTP Digest on each request.

## Britive Integration Setup

### 1. Create a Resource Type

In the Britive UI → Resource Manager → Resource Types, create a new type with:

- Checkout script: the appropriate `*-checkout.sh`
- Checkin script: the appropriate `*-checkin.sh`
- Variables matching the table in the subdirectory README

### 2. Configure Variables

Add the required variables to the Resource Type. Mark secrets (`client_secret`, `mongoDB_private_key`) as **sensitive** — Britive encrypts them at rest and injects them securely at runtime.

### 3. Create a Profile

In Britive Resource Manager → Profiles:

- Set `expiration_duration` (recommended: 1–4 hours for production, max 8 hours)
- Add an `approval` policy block for sensitive roles (`GROUP_OWNER`, `atlasAdmin`, `ORG_OWNER`)
- Associate the Resource Type and variables created above

## Variable Reference

### OAuth2 Scripts (DB Roles / Organization Role / Project Role)

These use Britive broker template substitution (`{{variable_name}}`):

| Variable | Description |
| -------- | ----------- |
| `client_id` | Atlas Service Account client ID |
| `client_secret` | Atlas Service Account client secret (**sensitive**) |
| `project_id` | Atlas project (group) ID |
| `org_id` | Atlas organization ID (Organization Role only) |
| `atlas_username` | Atlas username — usually the user's SSO email |
| `db_username` | Atlas database username (DB Roles only) |
| `db_checkout_role` | Database role to grant (DB Roles only) |
| `db_checkout_database` | Target database name (DB Roles only) |
| `org_role` | Org role to grant (Organization Role only) |
| `project_role` | Project role to grant (Project Role only) |

### API Key Scripts (On Premises MongoDB)

These read from environment variables (`${variable_name}`):

| Variable | Required | Description | Default |
| -------- | -------- | ----------- | ------- |
| `mongoDB_public_key` | Yes | Atlas API public key | — |
| `mongoDB_private_key` | Yes | Atlas API private key (**sensitive**) | — |
| `mongoDB_project_id` | Yes | Atlas project (group) ID | — |
| `mongoDB_username` | Yes | Full SSO email of the requesting user | — |
| `mongoDB_database` | No | Target database name | `sample_mflix` |
| `mongoDB_auth_source` | No | Auth source for the database user | `admin` |
| `LOG_DIR` | No | Log file directory on the broker host | `/tmp` |

## Troubleshooting

**`ERROR: Failed to obtain access token`**
Verify `client_id` and `client_secret`. Confirm the Service Account is active and has the required scope in Atlas.

**`ERROR: User not found in org / project`**
Confirm `atlas_username` exactly matches the Atlas username. Verify the user is a member of the organization.

**`ERROR: Role grant/revoke failed with HTTP 401`**
API key or Service Account credentials are invalid or expired. For Digest auth, verify the broker's egress IP is in the Atlas API access list.

**`ERROR: Role grant/revoke failed with HTTP 403`**
The Service Account or API key lacks the required permission scope. See scope requirements in each subdirectory's README.

**`ERROR: Required tool 'jq' is not installed`**
Install `jq` on the broker host: `apt install jq` or `yum install jq`.

## Security Best Practices

1. **Least Privilege** — use the narrowest permission type that satisfies the use case (DB role over Project role over Org role)
2. **Approval Gates** — require approval for sensitive roles (`GROUP_OWNER`, `atlasAdmin`, `ORG_OWNER`)
3. **Short Sessions** — use 1–4 hour expirations; avoid sessions longer than 8 hours for production
4. **IP Restriction** — restrict the Service Account and API keys to the broker's egress IP in Atlas Access Manager
5. **Atlas Audit Logs** — enable MongoDB Atlas database auditing to capture all role changes and auth events
6. **Rotate Secrets** — rotate `client_secret` and API keys on a regular schedule

## Resources

- [MongoDB Atlas Administration API v2](https://www.mongodb.com/docs/atlas/reference/api-resources-spec/v2/)
- [MongoDB Atlas OAuth 2.0 Service Accounts](https://www.mongodb.com/docs/atlas/atlas-ui/service-accounts/)
- [Britive Access Broker Documentation](https://docs.britive.com/)
- [Britive Resource Manager](https://docs.britive.com/docs/resource-manager)

---

**Security Notice:** Never commit credentials or API keys to this repository. Always store secrets in Britive's encrypted variable store or your organization's secret management solution.

---

The following video demonstrates Britive JIT access elevating a user to the `dbAdmin` role, and the checkin process revoking access automatically.

https://youtu.be/rBagcOYXzhw

<img width="806" height="479" alt="Britive Resource Type with Checkout and Checkin Scripts" src="https://github.com/user-attachments/assets/8c493f86-6bbf-427f-bb65-d26af732555f" />

<img width="1038" height="630" alt="Checkout - dbAdmin role granted" src="https://github.com/user-attachments/assets/71ce7571-e85c-475a-926e-21c97b67bbac" />

<img width="1038" height="630" alt="Checkin - access revoked" src="https://github.com/user-attachments/assets/f48f36da-c47e-4d7e-9580-27ac50e0fcad" />

<img width="509" height="677" alt="Access Broker Resource configuration" src="https://github.com/user-attachments/assets/3c9c8d29-f221-4685-9cb1-603870243a2f" />
