#!/bin/bash

# MongoDB Atlas API credentials
PUBLIC_KEY=""
PRIVATE_KEY=""
PROJECT_ID=""
USERNAME=""

# Test connection (silent)
TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID" 2>/dev/null)

HTTP_CODE="${TEST_RESPONSE: -3}"
if [ "$HTTP_CODE" != "200" ]; then
  exit 1
fi

# Update user roles (silent)
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
        "roleName": "dbAdmin",
        "databaseName": "sample_mflix"
      }
    ]
  }' 2>/dev/null)

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"
if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  exit 1
fi

# Verify the update (silent)
VERIFY_RESPONSE=$(curl -s \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID/databaseUsers/admin/$USERNAME" 2>/dev/null)

# Only show the final roles confirmation
echo "✅ Current roles for '$USERNAME':"
echo "$VERIFY_RESPONSE" | jq '.roles'
