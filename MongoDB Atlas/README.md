# MongoDB Atlas JIT ZSP Access with Britive

## Overview

This repository provides a secure Just-In-Time (JIT) access solution for MongoDB Atlas using Britive's Zero Standing Privileges (ZSP) approach. It eliminates permanent database credentials by dynamically creating and managing temporary user access only when needed, significantly reducing security risks and attack surface.

## 🔒 Security Benefits

- **Zero Standing Privileges**: No permanent database credentials exist, eliminating credential theft risks
- **Just-In-Time Access**: Database users are created only when needed and automatically removed after use
- **Audit Trail**: Complete visibility of who accessed what and when
- **Reduced Attack Surface**: Temporary credentials minimize exposure window
- **Compliance Ready**: Meets regulatory requirements for privileged access management

## 🏗️ Architecture

```
User Request → Britive Platform → Checkout Script → MongoDB Atlas API → Temporary User Created or Short Lived priviliged access enabled
                                                                      ↓
User Session ← Temporary Credentials ← Database Access Granted ←────
                                                                      ↓
Session End → Checkin Script → MongoDB Atlas API → Temporary User Deleted or Short Lived priviliged access revoked
```

## 📋 Prerequisites

- **Britive Platform** access with appropriate permissions
- **MongoDB Atlas** project with API access enabled
- **MongoDB Atlas API Keys** (Public and Private keys)
- **Britive Access Broker** configured for MongoDB Atlas

## 🚀 Quick Start

### 1. MongoDB Atlas Configuration

1. Generate MongoDB Atlas API Keys:
   - Log in to MongoDB Atlas
   - Navigate to **Organization Access Manager**
   - Go to **API Keys** → **Create API Key**
   - Assign `Organization Owner` or `Organization Project Creator` role
   - Save the Public and Private keys securely

2. Note your MongoDB Atlas Project ID:
   - Found in Project Settings → Project ID

### 2. Script Configuration

The solution consists of two main scripts:

#### Checkout Script (`mongoDB_dbAdmin_jit_checkout.sh`)
Assign temporary MongoDB Atlas dbAdmin permission upon access request.

```bash
# Environment variables required (provided by Britive)
PUBLIC_KEY="${mongoDB_public_key}"
PRIVATE_KEY="${mongoDB_private_key}"
PROJECT_ID="${mongoDB_project_id}"
USERNAME=${username}  # Automatically captured from SSO user email during checkout
```

#### Checkin Script (`mongoDB_dbAdmin_jit_checkin.sh`)
Revoke temporary MongoDB Atlas dbAdmin permission upon or checkin or timer expiry.

### 3. Britive Integration Setup


2. **Configure Britive Access Broker**:
   - Add MongoDB Atlas scripts in Britive UI
   - Configure environment variables:
     - `mongoDB_public_key`
     - `mongoDB_private_key`
     - `mongoDB_project_id`

3. **Create Profiles**:
   - Define access profiles (e.g., `dbAdmin`, `readOnly`, `readWrite`)
   - Associate checkout/checkin scripts with each profile
   - Set appropriate timeout values (recommended: 1-8 hours)


## 🔧 Configuration Details

### Environment Variables

| Variable | Description | Source |
|----------|-------------|--------|
| `mongoDB_public_key` | MongoDB Atlas API Public Key | MongoDB Atlas Console |
| `mongoDB_private_key` | MongoDB Atlas API Private Key | MongoDB Atlas Console |
| `mongoDB_project_id` | MongoDB Atlas Project ID | MongoDB Atlas Project Settings |
| `username` | User requesting access | Automatically captured by Britive using SSO email |

### Supported Database Roles

The scripts can support any MongoDB role. For instance:

- `atlasAdmin` - Full admin access
- `dbAdmin` - Database administration
- `readWriteAnyDatabase` - Read/write access to all databases
- `readAnyDatabase` - Read-only access to all databases
- Custom roles per specific database

## 🔍 Troubleshooting

### Common Issues

1. **HTTP 405 Error during role update**
   - Verify API endpoint and HTTP method
   - Check MongoDB Atlas API version compatibility
   - Ensure proper URL formatting with username variable populated

2. **Permission Denied**
   - Verify S3 bucket permissions for Britive Access Broker
   - Check MongoDB Atlas API key permissions
   - Ensure IP whitelist includes Britive broker IPs

3. **Username Processing Issues**
   - Verify the `username` environment variable is being passed correctly
   - Check variable name case sensitivity
   - Add debug logging to verify variable values


## 📊 Monitoring & Auditing

### Britive Audit Logs
- Track all checkout/checkin events
- Monitor access patterns
- Set up alerts for anomalous behavior

### MongoDB Atlas Audit
- Enable database audit logs
- Monitor temporary user activities
- Track permission changes

## 🛡️ Security Best Practices

1. **Least Privilege**: Grant minimum required permissions
2. **Time-bound Access**: Set appropriate session timeouts
3. **Regular Reviews**: Audit access patterns monthly
4. **Secure Storage**: Encrypt scripts in S3 with KMS
5. **Network Security**: Restrict MongoDB Atlas access to specific IPs

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Resources / Acknowledgments

- [Britive](https://www.britive.com/) for the Zero Standing Privileges platform
- [MongoDB Atlas](https://www.mongodb.com/atlas) for the database platform

## 📞 Support

For issues and questions:
- Create an issue in this repository
- Contact your Britive administrator
- Refer to [MongoDB Atlas API Documentation](https://docs.atlas.mongodb.com/api/)
- Check [Britive Documentation](https://docs.britive.com/)

---

**Security Notice**: Never commit credentials or sensitive information to this repository. Always use environment variables or secure secret management solutions.



** Follwoing vides show Britive JIT access to elevate a user permission to dbAdmin role. And then Britive checkin process remove or revoke the access back to read mode in MongoDB Atlas. 

https://youtu.be/rBagcOYXzhw

Resoruce Type contains Checkout and Checkin Scripts

<img width="806" height="479" alt="image" src="https://github.com/user-attachments/assets/8c493f86-6bbf-427f-bb65-d26af732555f" />

--

<img width="1038" height="630" alt="image" src="https://github.com/user-attachments/assets/71ce7571-e85c-475a-926e-21c97b67bbac" />

--

<img width="1038" height="630" alt="image" src="https://github.com/user-attachments/assets/f48f36da-c47e-4d7e-9580-27ac50e0fcad" />

--

<img width="509" height="677" alt="Access Broker Resource" src="https://github.com/user-attachments/assets/3c9c8d29-f221-4685-9cb1-603870243a2f" />


