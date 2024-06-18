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


# Remove a user from a Google Workspace group
def remove_user_from_group(identity, group_email, secret_name):
    service = get_google_service(secret_name, 'admin', 'directory_v1')
    service.members().delete(groupKey=group_email, memberKey=identity).execute()
    print(f"{identity} removed from group {group_email}")


# Main function to add identity to group and role
def main():
    secret_name = os.getenv('SECRET')
    identity = os.getenv('IDENTITY')
    group = os.getenv('GROUP')

    remove_user_from_group(identity=identity, group_email=group, secret_name=secret_name)