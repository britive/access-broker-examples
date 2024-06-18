import os
import boto3
from google.oauth2 import service_account
from googleapiclient.discovery import build


# Retrieve AWS Secrets Manager credentials
def get_google_credentials(secret_name):
    client = boto3.client('secretsmanager')
    secret = client.get_secret_value(SecretId=secret_name)
    return secret['SecretString']


# Authenticate to Google Workspace API
def get_google_service(secret_name, service_name, version):
    credentials_data = get_google_credentials(secret_name)
    credentials = service_account.Credentials.from_service_account_info(credentials_data)
    return build(service_name, version, credentials=credentials)


# Add a user to a Google Workspace group
def add_user_to_group(identity, group_email, secret_name):
    service = get_google_service(secret_name, 'admin', 'directory_v1')
    group_members = service.members()
    group_members.insert(groupKey=group_email, body={'email': identity, 'role': 'MEMBER'}).execute()
    print(f"{identity} added to group {group_email}")


# Main function to add identity to group and role
def main():
    secret_name = os.getenv('SECRET')
    identity = os.getenv('IDENTITY')
    group = os.getenv('GROUP')

    add_user_to_group(identity=identity, group_email=group, secret_name=secret_name)


if __name__ == "__main__":
    main()
