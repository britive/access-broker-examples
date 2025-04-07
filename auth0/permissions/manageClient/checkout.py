from auth0.management import Auth0
from auth0.authentication import GetToken
import os
from dotenv import load_dotenv

load_dotenv()
domain = os.getenv("auth_domain")
non_interactive_client_id = os.getenv("auth_client_id")
non_interactive_client_secret = os.getenv("auth_client_secret")


get_token = GetToken(domain, non_interactive_client_id, client_secret=non_interactive_client_secret)
token = get_token.client_credentials('https://{}/api/v2/'.format(domain))
mgmt_api_token = token['access_token']


mgmt_api_token = 'MGMT_API_TOKEN'

auth0 = Auth0(domain, mgmt_api_token)


new_client = auth0.clients.create({
    'name': 'New Application Client',
    'description': 'This is a new application client',
    # Add other client parameters as needed
})
print(new_client)
