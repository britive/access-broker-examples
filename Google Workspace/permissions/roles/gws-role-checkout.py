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


# Add a user to a Google Workspace role (Admin role)
def add_user_to_role(identity, role_name, secret_name):
    service = get_google_service(secret_name, 'admin', 'directory_v1')
    roles = service.roles()
    role = roles.insert(roleId=role_name, body={'assignedTo': identity}).execute()
    print(f"{identity} added to role {role_name}")


# Main function to add identity to group and role
def main():
    secret_name = os.getenv('SECRET')
    identity = os.getenv('IDENTITY')
    role = os.getenv('ROLE')
    add_user_to_role(identity=identity, role_name=role, secret_name=secret_name)