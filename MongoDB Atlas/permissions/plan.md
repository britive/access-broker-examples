# Plan: MongoDB Atlas JIT Access via Native API vs. Shell Scripts

## Current Approach (Shell Scripts)

The existing Britive Access Broker integration uses two shell scripts:

| Script | Action | API Call |
|--------|--------|----------|
| `mongoDB_dbAdmin_checkout.sh` | Elevate user to `dbAdmin` | `PATCH /groups/{projectId}/databaseUsers/admin/{username}` |
| `mongoDB_dbAdmin_checkin.sh` | Restore user to `read` | `PATCH /groups/{projectId}/databaseUsers/admin/{username}` |

Both scripts use [MongoDB Atlas Administration API v2](https://www.mongodb.com/docs/atlas/reference/api-resources-spec/v2/) with Digest authentication.

---

## Alternative: Pure MongoDB Atlas API Approach

The same JIT access lifecycle can be implemented entirely via MongoDB Atlas API calls, without shell scripts. This is viable for direct API integrations, custom automation tools, or replacing the shell-based broker scripts.

### Option 1: Role Patch (Current Pattern — API-native)

This is exactly what the shell scripts do today. It can be called directly from any HTTP client or automation platform (Terraform, Python, Postman, CI/CD).

**Checkout (elevate):**
```
PATCH https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/databaseUsers/admin/{username}
Authorization: Digest (public_key:private_key)
Accept: application/vnd.atlas.2023-01-01+json
Content-Type: application/json

{
  "roles": [{ "roleName": "dbAdmin", "databaseName": "sample_mflix" }]
}
```

**Checkin (restore):**
```
PATCH https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/databaseUsers/admin/{username}

{
  "roles": [{ "roleName": "read", "databaseName": "sample_mflix" }]
}
```

**Trade-offs:**
- ✅ No shell scripting needed
- ✅ Language-agnostic — works from Python, Node, Terraform, etc.
- ⚠️ Requires the user to pre-exist in MongoDB Atlas (managed separately)
- ⚠️ A PATCH replaces ALL roles — if the user has roles on multiple databases, they will be removed

---

### Option 2: Temporary User Creation / Deletion (True Zero Standing Privileges)

Instead of modifying an existing user's roles, create a net-new database user on checkout and delete them on checkin. This is the strongest ZSP posture — no standing user exists at all.

**Checkout (create temp user):**
```
POST https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/databaseUsers

{
  "databaseName": "admin",
  "username": "{derived_username}_tmp_{timestamp}",
  "password": "{generated_secure_password}",
  "roles": [{ "roleName": "dbAdmin", "databaseName": "sample_mflix" }]
}
```

**Checkin (delete temp user):**
```
DELETE https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/databaseUsers/admin/{username}
```

**Trade-offs:**
- ✅ True zero-standing-privileges — user does not exist between sessions
- ✅ Clean audit trail in MongoDB Atlas logs (user create/delete events)
- ✅ No risk of overwriting other roles on the base user
- ⚠️ Requires a mechanism to pass the generated password back to the user (via Britive response template)
- ⚠️ Username must be tracked between checkout and checkin (store as a Britive session variable)
- ⚠️ If checkin fails, orphaned users may need a cleanup job

---

### Option 3: MongoDB Atlas Temporary Auth Tokens (Atlas Data API / App Services)

MongoDB Atlas App Services supports short-lived JWT tokens for database access. This approach issues a time-bound token instead of managing user roles.

**Flow:**
1. Checkout: call App Services authentication endpoint → receive JWT with expiry
2. User connects to MongoDB using the JWT (no username/password rotation needed)
3. Checkin: token expires naturally OR call revoke endpoint

**Trade-offs:**
- ✅ Native time-bound access — no checkin script required for expiry
- ✅ No Atlas Admin API keys exposed to end users
- ⚠️ Requires MongoDB Atlas App Services to be configured and enabled
- ⚠️ Not suited for all driver-level MongoDB access (works best with Atlas Data API or App Services SDK)
- ⚠️ More complex initial setup

---

### Option 4: IP Access List Pairing

Combine role management (Option 1 or 2) with dynamic IP access list management to add network-layer JIT control.

**Checkout (add IP):**
```
POST https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/accessList

{
  "ipAddress": "{broker_egress_ip}",
  "comment": "Britive JIT session for {username} - {timestamp}"
}
```

**Checkin (remove IP):**
```
DELETE https://cloud.mongodb.com/api/atlas/v2/groups/{projectId}/accessList/{ipAddress}
```

**Trade-offs:**
- ✅ Defense in depth — even with leaked credentials, access is IP-restricted
- ✅ Works alongside any of the above options
- ⚠️ Only viable if the Britive broker has a stable egress IP
- ⚠️ Atlas has a limit of 200 IP access list entries per project

---

## Recommendation

| Scenario | Recommended Approach |
|----------|---------------------|
| Existing users, simplest change | **Option 1** (current shell script pattern, call API directly) |
| Strongest security posture | **Option 2** (temp user create/delete) |
| App Services already in use | **Option 3** (JWT tokens) |
| All environments | **Option 4** as an additive layer on top of 1 or 2 |

For a production Britive Access Broker deployment with the highest ZSP assurance, **Option 2 + Option 4** is the recommended target state:
- Create an ephemeral user on checkout (no standing user)
- Delete the user on checkin
- Restrict database access to the broker's egress IP during the session

---

## Migration Path from Shell Scripts to Pure API

If migrating away from shell scripts to a direct API integration (e.g., via Britive's native HTTP connector or a custom automation tool):

1. **Replace checkout script** → `POST /databaseUsers` (create temp user) or `PATCH /databaseUsers/{username}` (modify existing)
2. **Replace checkin script** → `DELETE /databaseUsers/admin/{username}` (delete temp) or `PATCH /databaseUsers/{username}` (restore roles)
3. **Store session state** → if using temp users, the generated username must be stored in the Britive session context so checkin knows which user to delete
4. **Error handling** → add a periodic cleanup job to remove orphaned temp users older than the max session duration
5. **Audit** → enable MongoDB Atlas Database Auditing to capture all user create/delete/auth events

---

## API Reference

| Operation | Method | Endpoint |
|-----------|--------|----------|
| Get project | GET | `/api/atlas/v2/groups/{groupId}` |
| List database users | GET | `/api/atlas/v2/groups/{groupId}/databaseUsers` |
| Get database user | GET | `/api/atlas/v2/groups/{groupId}/databaseUsers/{authSource}/{userName}` |
| Create database user | POST | `/api/atlas/v2/groups/{groupId}/databaseUsers` |
| Update database user roles | PATCH | `/api/atlas/v2/groups/{groupId}/databaseUsers/{authSource}/{userName}` |
| Delete database user | DELETE | `/api/atlas/v2/groups/{groupId}/databaseUsers/{authSource}/{userName}` |
| Add IP to access list | POST | `/api/atlas/v2/groups/{groupId}/accessList` |
| Remove IP from access list | DELETE | `/api/atlas/v2/groups/{groupId}/accessList/{entryValue}` |

Full API spec: https://www.mongodb.com/docs/atlas/reference/api-resources-spec/v2/
