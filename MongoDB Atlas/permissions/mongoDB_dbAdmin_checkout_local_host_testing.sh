#!/bin/bash
# =============================================================================
# MongoDB Atlas JIT Access - LOCAL TESTING SCRIPT (dbAdmin)
# =============================================================================
# ⚠️  FOR DEVELOPMENT / LOCAL TESTING ONLY — DO NOT DEPLOY TO PRODUCTION ⚠️
#
# Purpose : Manual validation of the checkout flow against a real MongoDB Atlas
#           project before deploying scripts to the Britive Access Broker.
#
# Usage   : Fill in your real PUBLIC_KEY, PRIVATE_KEY, PROJECT_ID, and USERNAME
#           below, then run:  bash mongoDB_dbAdmin_checkout_local_host_testing.sh
#
# What it does differently from the production checkout script:
#   - Credentials are hardcoded (NOT read from env vars) for easy local use
#   - Verbose output with full JSON responses for debugging
#   - Lists all database users at the end for visual confirmation
#   - Sets role to 'read' (safe default for testing — change as needed)
# =============================================================================

# ---------------------------------------------------------------------------
# ⚠️  Fill in test credentials below — NEVER commit real keys to source control
# ---------------------------------------------------------------------------
PUBLIC_KEY="your_public_key_here"
PRIVATE_KEY="your_private_key_here"
PROJECT_ID="your_project_id_here"
USERNAME="your_test_username_here"     # MongoDB Atlas username (not email)
DATABASE="${DATABASE:-sample_mflix}"   # Override via env var if needed

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Required tool '$cmd' is not installed or not on PATH."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Step 1: Test API connectivity
# ---------------------------------------------------------------------------
echo "🔍 Testing API connection to project '${PROJECT_ID}'..."

TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}")

HTTP_CODE="${TEST_RESPONSE: -3}"
RESPONSE_BODY="${TEST_RESPONSE%???}"

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ API connection failed. HTTP Code: ${HTTP_CODE}"
  echo "Response body: ${RESPONSE_BODY}"
  exit 1
fi

echo "✅ API connection successful (HTTP ${HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 2: Update user role (set to 'read' for safe local testing)
# Change 'read' to 'dbAdmin' to test the actual checkout elevation.
# ---------------------------------------------------------------------------
echo ""
echo "🔄 Updating role for user '${USERNAME}' on database '${DATABASE}'..."

UPDATE_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request PATCH \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --header "Content-Type: application/json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${USERNAME}" \
  --data "{
    \"roles\": [
      {
        \"roleName\": \"read\",
        \"databaseName\": \"${DATABASE}\"
      }
    ]
  }")

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"
UPDATE_BODY="${UPDATE_RESPONSE%???}"

if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  echo "❌ Role update failed. HTTP Code: ${UPDATE_HTTP_CODE}"
  echo "Response body: ${UPDATE_BODY}"
  exit 1
fi

echo "✅ Role update successful (HTTP ${UPDATE_HTTP_CODE})."

# ---------------------------------------------------------------------------
# Step 3: Verify updated roles
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Verifying updated roles for '${USERNAME}'..."

VERIFY_RESPONSE=$(curl -s \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers/admin/${USERNAME}")

echo ""
echo "📋 Full user details:"
echo "$VERIFY_RESPONSE" | jq '.'

echo ""
echo "✅ Current roles for '${USERNAME}':"
echo "$VERIFY_RESPONSE" | jq '.roles'

# ---------------------------------------------------------------------------
# Step 4: List all database users in the project (useful for verification)
# ---------------------------------------------------------------------------
echo ""
echo "📋 All database users in project '${PROJECT_ID}':"

USER_LIST=$(curl -s \
  --user "${PUBLIC_KEY}:${PRIVATE_KEY}" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/${PROJECT_ID}/databaseUsers")

echo "$USER_LIST" | jq '.results[] | {username: .username, databaseName: .databaseName, roles: .roles}'
