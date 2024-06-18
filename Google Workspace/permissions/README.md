# Google Workspace Management Scripts

This project provides Python and Bash scripts to manage Google Workspace identities, specifically for adding and removing a Google Workspace user (identity) to and from a group and a role. The scripts use AWS Secrets Manager to securely store and retrieve Google Workspace credentials.

## Requirements

- **Google Workspace Admin SDK**: The Google Workspace API must be enabled for your organization.
- **AWS CLI**: Used to retrieve Google Workspace credentials from AWS Secrets Manager in the Bash script.
- **Boto3**: The AWS SDK for Python, used in the Python script to interact with AWS Secrets Manager.
- **jq**: A command-line JSON processor used in the Bash script for parsing JSON data.
- **Google API Python Client**: Required for Python scripts to interact with Google Workspace API.

## Setup and Installation

### Step 1: Enable Google Workspace Admin API
1. Go to [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the **Admin SDK API**.
3. Create a service account and download the JSON key file.
4. Store the key securely in **AWS Secrets Manager**.

### Step 2: Store Google Workspace Credentials in AWS Secrets Manager
1. Open AWS Secrets Manager in your AWS Console.
2. Choose **Store a new secret** and select **Other type of secret**.
3. Paste the JSON key of the Google Workspace service account into the secret value field.
4. Save the secret and note down the **Secret Name** (you’ll use this in environment variables).

### Step 3: Install Required Packages

#### Python Requirements

Install the required Python packages:
```bash
pip install boto3 google-auth google-auth-oauthlib google-auth-httplib2 google-api-python-client
```

#### Bash Requirements
Ensure `jq` is installed:  
```bash
# For Debian/Ubuntu
sudo apt-get install jq
# For MacOS
brew install jq
```

## Environment Variables

Set up the following environment variables:  
`GWS_SECRET_NAME`: The name of the AWS Secret storing Google Workspace credentials.  
`GWS_IDENTITY`: The Google Workspace user email to add/remove from groups and roles.  
`GWS_GROUP`: The Google Workspace group email.  
`GWS_ROLE`: The Google Workspace role ID (use the Admin SDK role ID if using Admin roles).  


## Functions

Both scripts provide the following functions:  
`Add User to Group`: Adds a specified user (identity) to a Google Workspace group.  
`Remove User from Group`: Removes a specified user from a Google Workspace group.  
`Add User to Role`: Assigns a specified user to a Google Workspace role.  
`Remove User from Role`: Removes a specified user from a Google Workspace role.  


### Modifying the Scripts
In both scripts, you can comment or uncomment functions in the main execution section to perform only specific operations (e.g., only adding a user to a group).


## Notes

Ensure your Google Workspace Admin has delegated the necessary permissions to the service account.
AWS credentials must be configured for the CLI and Boto3 to access AWS Secrets Manager.

## Troubleshooting

Permission Issues: Make sure the Google Workspace service account has the required permissions to manage groups and roles.  
AWS Secret Retrieval: Ensure the AWS CLI is configured properly and that the IAM role/user has access to the secret in AWS Secrets Manager.  
API Rate Limits: Google Workspace APIs have usage limits; be mindful if performing bulk operations.  

## Contributing
Contributions are welcome! Please submit a pull request or open an issue to discuss improvements.