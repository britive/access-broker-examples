#!/bin/bash

# Checkin routing/script will change the permissions back to DB reader only
# MongoDB Atlas API credentials

# MongoDB Atlas API credentials
PUBLIC_KEY="${mongoDB_public_key}"
PRIVATE_KEY="${mongoDB_private_key}"
PROJECT_ID="${mongoDB_project_id}"
USERNAME="${mongoDB_username}"              # Get the full email address Britive checkout process

USERNAME="${USERNAME%%@*}"                  # Extract everything before '@'
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"       # Remove any non-alphanumeric characters


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
        "roleName": "read",
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
