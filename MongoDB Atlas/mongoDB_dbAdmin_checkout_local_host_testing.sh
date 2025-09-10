#!/bin/bash

# MongoDB Atlas API credentials
PUBLIC_KEY="mnpleppf"
PRIVATE_KEY=""
PROJECT_ID=""
USERNAME=""

echo "🔍 Testing API connection..."

# Test connection first
TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID")

HTTP_CODE="${TEST_RESPONSE: -3}"
RESPONSE_BODY="${TEST_RESPONSE%???}"

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ API connection failed. HTTP Code: $HTTP_CODE"
  echo "Response: $RESPONSE_BODY"
  exit 1
fi

echo "✅ API connection successful."

echo "🔄 Updating user role for '$USERNAME'..."

# Update user roles
UPDATE_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request PATCH \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --header "Content-Type: application/json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID/databaseUsers/admin/$USERNAME" \
  --data '{
    "roles": [
      {
        "roleName": "read",
        "databaseName": "sample_mflix"
      }
    ]
  }')

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"
UPDATE_BODY="${UPDATE_RESPONSE%???}"

if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  echo "❌ Failed to update user role. HTTP Code: $UPDATE_HTTP_CODE"
  echo "Response: $UPDATE_BODY"
  exit 1
fi

echo "✅ Role update successful."

echo "🔍 Verifying updated roles for '$USERNAME'..."

# Verify the update
VERIFY_RESPONSE=$(curl -s \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID/databaseUsers/admin/$USERNAME")

echo "📋 Updated user details:"
echo "$VERIFY_RESPONSE" | jq '.'

echo "✅ Current roles for '$USERNAME':"
echo "$VERIFY_RESPONSE" | jq '.roles'

echo "📋 Listing all database users in project..."

# List all database users
USER_LIST=$(curl -s \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID/databaseUsers")

echo "$USER_LIST" | jq '.results[] | {username: .username, databaseName: .databaseName, roles: .roles}'
