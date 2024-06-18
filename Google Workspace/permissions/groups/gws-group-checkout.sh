#!/bin/bash

# Required Environment Variables
CREDENTIALS_FILE=${GWS_CREDS_FILE}  # Path to your service account JSON file
IDENTITY=${GWS_USER}
GROUP=${GWS_GROUP}
ADMIN=${GWS_ADMIN}

# Check if the credentials file exists
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "Credentials file not found: $CREDENTIALS_FILE"
    exit 1
fi

# Prepare and extract required information from the credentials JSON
CLIENT_EMAIL=$(jq -r '.client_email' < "$CREDENTIALS_FILE")
PRIVATE_KEY=$(jq -r '.private_key' < "$CREDENTIALS_FILE" | sed 's/\\n/\n/g')  # Ensure newlines are preserved
TOKEN_URI="https://oauth2.googleapis.com/token"
NOW=$(date +%s)
EXP=$((NOW + 3600))

# Create the JWT
HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-')
PAYLOAD=$(echo -n "{\"iss\":\"$CLIENT_EMAIL\",\"sub\":\"$ADMIN\",\"scope\":\"https://www.googleapis.com/auth/admin.directory.group https://www.googleapis.com/auth/admin.directory.group.member\",\"aud\":\"$TOKEN_URI\",\"exp\":$EXP,\"iat\":$NOW}" | base64 | tr -d '=' | tr '/+' '_-')
JWT="${HEADER}.${PAYLOAD}"

# Sign the JWT using the private key
SIGNATURE=$(echo -n "$JWT" | openssl dgst -sha256 -sign <(echo -e "$PRIVATE_KEY") | base64 | tr -d '=' | tr '/+' '_-')

# Create the complete JWT
ID_TOKEN="${JWT}.${SIGNATURE}"

# Exchange the JWT for an access token
ACCESS_TOKEN=$(curl -s -X POST "$TOKEN_URI" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$ID_TOKEN" | jq -r '.access_token')

# Function to add a user to Google Workspace group
add_user_to_group() {
    curl -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$IDENTITY\", \"role\": \"MEMBER\"}" \
        "https://admin.googleapis.com/admin/directory/v1/groups/$GROUP/members"
    echo "Added $IDENTITY to group $GROUP"
}

# Execute functions
add_user_to_group
