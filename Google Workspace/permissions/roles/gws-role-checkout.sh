#!/bin/bash

# Required Environment Variables
CREDENTIALS_FILE=${GWS_CREDS_FILE}  # Path to your service account JSON file
IDENTITY=${user}
ROLE_NAME=${role}
CUSTOMER_ID=${customer}
ADMIN=${admin}

ROLE_ID=''
USER_ID=''


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
PAYLOAD=$(echo -n "{\"iss\":\"$CLIENT_EMAIL\",\"sub\":\"$ADMIN\",\"scope\":\"https://www.googleapis.com/auth/admin.directory.user https://www.googleapis.com/auth/admin.directory.user.readonly https://www.googleapis.com/auth/admin.directory.group https://www.googleapis.com/auth/admin.directory.group.member https://www.googleapis.com/auth/admin.directory.rolemanagement\",\"aud\":\"$TOKEN_URI\",\"exp\":$EXP,\"iat\":$NOW}" | base64 | tr -d '=' | tr '/+' '_-')


JWT="${HEADER}.${PAYLOAD}"


# Sign the JWT using the private key
SIGNATURE=$(echo -n "$JWT" | openssl dgst -sha256 -sign <(echo -e "$PRIVATE_KEY") | base64 | tr -d '=' | tr '/+' '_-')


# Create the complete JWT
ID_TOKEN="${JWT}.${SIGNATURE}"

# Exchange the JWT for an access token
ACCESS_TOKEN=$(curl -s -X POST "$TOKEN_URI" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$ID_TOKEN" | jq -r '.access_token')


# Get Role id with pagination
get_role_id(){
    # Base API endpoint to list all roles
    API_URL="https://admin.googleapis.com/admin/directory/v1/customer/$CUSTOMER_ID/roles"

    # Initialize an empty nextPageToken and set FOUND flag
    nextPageToken=""
    found=0

    # Loop to handle pagination
    while :; do
      # If there's a nextPageToken, add it to the API request
      if [ -n "$nextPageToken" ]; then
        response=$(curl -s -X GET \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API_URL}?pageToken=${nextPageToken}")
      else
        response=$(curl -s -X GET \
          -H "Authorization: Bearer ${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          "${API_URL}")
      fi

      # Check for errors in the response
      if echo "$response" | grep -q "error"; then
        echo "Error: $(echo "$response" | jq '.error.message')"
        exit 1
      fi

      # Search for the specified role name in the current page
      role=$(echo "$response" | jq --arg ROLE_NAME "$ROLE_NAME" '.items[] | select(.roleName == $ROLE_NAME)')

      if [ -n "$role" ]; then
        ROLE_ID=$(echo "$role" | jq -r '.roleId')
        echo "ROLE_ID: $ROLE_ID"
        found=1
        break
      fi

      # Check for a nextPageToken to continue pagination
      nextPageToken=$(echo "$response" | jq -r '.nextPageToken // empty')

      # If no nextPageToken is found, exit the loop
      if [ -z "$nextPageToken" ]; then
        break
      fi
    done

    # If the role was not found after all pages were checked
    if [ $found -eq 0 ]; then
      echo "Role '$ROLE_NAME' not found."
    fi
}

# Get User's GUID from Email address
get_user_id(){
    RESPONSE=$(curl -s -X GET \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        "https://admin.googleapis.com/admin/directory/v1/users/$IDENTITY")

    # Check if the response contains user information or an error
    if echo "$RESPONSE" | grep -q "error"; then
        echo "Error: $(echo "$RESPONSE" | jq '.error.message')"
    else
        USER_ID=$(echo "$RESPONSE" | jq -r '.id')
fi
}

# Function to assign a role to a user
assign_role_to_user() {
    # Get role and User ID from Role name and user's email address
    get_role_id
    get_user_id

    # Process Assignment
    RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"roleId\": \"$ROLE_ID\", \"assignedTo\": \"$USER_ID\", \"scopeType\": \"CUSTOMER\"}" \
        "https://admin.googleapis.com/admin/directory/v1/customer/$CUSTOMER_ID/roleassignments")

    if [[ $(echo "$RESPONSE" | jq -r '.error') ]]; then
        echo "Error assigning role to user: $RESPONSE"
    else
        echo "Assigned role $ROLE_ID to user $USER_ID"
    fi
}


# Execute functions
assign_role_to_user