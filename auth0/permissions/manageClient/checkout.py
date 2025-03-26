from auth0.management import Auth0

domain = 'your-auth0-domain'
mgmt_api_token = 'your-management-api-access-token'

auth0 = Auth0(domain, mgmt_api_token)
new_client = auth0.clients.create({
    'name': 'New Application Client',
    'description': 'This is a new application client',
    # Add other client parameters as needed
})
print(new_client)
