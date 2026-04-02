# MongoDB Atlas JIT Access — Project Roles

Grant and revoke project-level roles (e.g. `GROUP_READ_ONLY`, `GROUP_DATA_ACCESS_READ_WRITE`) for a user within a MongoDB Atlas project. The checkout script handles both new and existing project members correctly.

## Scripts

| Script | Trigger | Action |
|--------|---------|--------|
| `project-role-checkout.sh` | Profile checkout | Grants `{{project_role}}` to the user in the project |
| `project-role-checkin.sh` | Profile checkin / timer expiry | Revokes `{{project_role}}` from the user; removes from project if it was their last role |

## Authentication

Uses **MongoDB Atlas OAuth 2.0** (`client_credentials` grant) via a Service Account.

Required Service Account scope: **Project Owner**.

## Britive Variable Configuration

Configure these variables in the Britive Resource Manager permission definition:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `client_id` | Yes | OAuth2 Service Account client ID | `abc123def` |
| `client_secret` | Yes | OAuth2 Service Account client secret | (stored as secret) |
| `project_id` | Yes | Atlas project (group) ID | `6371e1e1c5a7e23b12345678` |
| `atlas_username` | Yes | Atlas username (usually user's email) | `jane.smith@example.com` |
| `project_role` | Yes | Project role to grant | `GROUP_READ_ONLY`, `GROUP_OWNER` |

## Supported Project Roles

| Role | Description |
|------|-------------|
| `GROUP_OWNER` | Full project admin |
| `GROUP_CLUSTER_MANAGER` | Manage cluster configuration |
| `GROUP_DATA_ACCESS_ADMIN` | Full data access across all databases |
| `GROUP_DATA_ACCESS_READ_WRITE` | Read/write on all databases in the project |
| `GROUP_DATA_ACCESS_READ_ONLY` | Read-only on all databases in the project |
| `GROUP_READ_ONLY` | View-only access to project configuration |

## Checkout Logic

The checkout script handles two scenarios:

1. **User not yet in project** — Adds the user directly with the requested role via `POST /groups/{id}/users`.
2. **User already in project** — Appends the role atomically via `POST /groups/{id}/users/{userId}:addRole`, leaving existing roles intact. A 409 (role already held) is treated as success.

## Checkin Logic

The checkin script also handles two scenarios:

1. **User has multiple roles** — Removes only the JIT role via `POST /groups/{id}/users/{userId}:removeRole`.
2. **User's last project role** — A 403 `CANNOT_REMOVE_LAST_GROUP_ROLE` triggers a full project membership removal via `DELETE /groups/{id}/users/{userId}`, leaving the user with no project access (true ZSP).

## Security Notes

- `client_secret` is passed via the HTTP Authorization header — never appears in process listings or logs.
- Concurrent Britive sessions each use isolated `mktemp` files for API responses.
- Atomic role endpoints (`:addRole`, `:removeRole`) avoid TOCTOU races compared to a read-modify-write PATCH.
