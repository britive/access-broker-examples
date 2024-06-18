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


# Remove a user from a Google Workspace role
def remove_user_from_role(identity, role_name, secret_name):
    service = get_google_service(secret_name, 'admin', 'directory_v1')
    roles = service.roleAssignments()
    role_assignments = roles.list(customer='my_customer', userKey=identity).execute()
    for assignment in role_assignments.get('items', []):
        if assignment['roleId'] == role_name:
            roles.delete(customer='my_customer', roleAssignmentId=assignment['roleAssignmentId']).execute()
            print(f"{identity} removed from role {role_name}")


# Main function to add identity to group and role
def main():
    secret_name = os.getenv('SECRET')
    identity = os.getenv('IDENTITY')
    role_name = os.getenv('ROLE')
    remove_user_from_role(identity=identity, role_name=role_name, secret_name=secret_name)