# MongoDB Atlas JIT Access — Organization Roles

Grant and revoke organization-level roles (e.g. `ORG_MEMBER`, `ORG_READ_ONLY`) for a user within a MongoDB Atlas organization. Roles are **additive** — existing org roles are preserved and only the JIT role is removed on checkin.

## Scripts

| Script | Trigger | Action |
|--------|---------|--------|
| `org-role-checkout.sh` | Profile checkout | Appends `{{org_role}}` to the user's org roles |
| `org-role-checkin.sh` | Profile checkin / timer expiry | Removes `{{org_role}}` from the user's org roles |

## Authentication

Uses **MongoDB Atlas OAuth 2.0** (`client_credentials` grant) via a Service Account.

Required Service Account scope: **Organization Owner**.

## Britive Variable Configuration

Configure these variables in the Britive Resource Manager permission definition:

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `client_id` | Yes | OAuth2 Service Account client ID | `abc123def` |
| `client_secret` | Yes | OAuth2 Service Account client secret | (stored as secret) |
| `org_id` | Yes | Atlas organization ID | `5e2211c17a3e5a48f5497999` |
| `atlas_username` | Yes | Atlas username (usually user's email) | `jane.smith@example.com` |
| `org_role` | Yes | Organization role to grant | `ORG_READ_ONLY`, `ORG_MEMBER` |

## Supported Organization Roles

| Role | Description |
|------|-------------|
| `ORG_OWNER` | Full organization admin |
| `ORG_MEMBER` | View projects and clusters |
| `ORG_GROUP_CREATOR` | Create new projects |
| `ORG_BILLING_ADMIN` | Manage billing and invoices |
| `ORG_READ_ONLY` | Read-only access to org resources |

## Security Notes

- `client_secret` is passed via the HTTP Authorization header — never appears in process listings or logs.
- The user is looked up by username (not hardcoded ID), so the scripts are portable across organizations.
- Concurrent Britive sessions each use an isolated `mktemp` file for API responses.
- Only the exact `org_role` string is removed on checkin — other org roles are preserved.
