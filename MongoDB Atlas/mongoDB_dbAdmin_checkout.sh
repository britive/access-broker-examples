#!/bin/bash

LOG_FILE="/Users/shahzadali/britive-broker/logs/mongoDB_dbAdmin_checkout.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# MongoDB Atlas API credentials
PUBLIC_KEY="${mongoDB_public_key}"
PRIVATE_KEY="${mongoDB_private_key}"
PROJECT_ID="${mongoDB_project_id}"
USERNAME="${mongoDB_username}"              # Get the full email address Britive checkout process

USERNAME="${USERNAME%%@*}"                  # Extract everything before '@'
USERNAME="${USERNAME//[^a-zA-Z0-9]/}"       # Remove any non-alphanumeric characters


log "Starting MongoDB Atlas API script..."

# Test connection
log "Testing connection to MongoDB Atlas..."
TEST_RESPONSE=$(curl -s -w "%{http_code}" \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID")

HTTP_CODE="${TEST_RESPONSE: -3}"
if [ "$HTTP_CODE" != "200" ]; then
  log "❌ Connection test failed with HTTP code $HTTP_CODE"
  exit 1
else
  log "✅ Connection test succeeded with HTTP code $HTTP_CODE"
fi

# Update user roles
log "Updating roles for user '$USERNAME'..."
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
  }')

UPDATE_HTTP_CODE="${UPDATE_RESPONSE: -3}"
if [ "$UPDATE_HTTP_CODE" != "200" ]; then
  log "❌ Role update failed with HTTP code $UPDATE_HTTP_CODE"
  exit 1
else
  log "✅ Role update succeeded with HTTP code $UPDATE_HTTP_CODE"
fi

# Verify the update
log "Verifying updated roles for user '$USERNAME'..."
VERIFY_RESPONSE=$(curl -s \
  --user "$PUBLIC_KEY:$PRIVATE_KEY" \
  --digest \
  --request GET \
  --header "Accept: application/vnd.atlas.2023-01-01+json" \
  --url "https://cloud.mongodb.com/api/atlas/v2/groups/$PROJECT_ID/databaseUsers/admin/$USERNAME")

log "✅ Current roles for '$USERNAME':"
echo "$VERIFY_RESPONSE" | jq '.roles' | tee -a "$LOG_FILE"

log "Script completed successfully."
