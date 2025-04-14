# Britive Access Broker VyOS ZSP Sample Scripts

This repository contains sample scripts designed to demonstrate the integration of Britive's Access Broker with VyOS routers, enabling Zero Standing Privileges (ZSP) for enhanced security and dynamic access management.

## Overview

Britive's Access Broker extends the power of Cloud Privileged Access Management (CPAM) to on-premises and hybrid environments. These scripts showcase how to leverage Britive's capabilities to achieve:

- Just-In-Time (JIT) ephemeral access to VyOS routers.
- Zero Standing Privileges (ZSP) for secure and compliant operations.
- Simplified and automated access management.

## Features

- **Dynamic Access Control**: Automate the provisioning and revocation of access to VyOS routers.
- **Zero Trust Security**: Enforce least privilege principles with time-bound permissions.
- **Integration Ready**: Easily integrate with existing CI/CD pipelines and infrastructure.

## Prerequisites

1. A Britive account with Access Broker enabled.
2. A VyOS router configured for remote access.
3. Python 3.8+ installed on your system.
4. Required Python libraries (see `https://docs.britive.com`).

## Setup Instructions

1. Clone this repository
2. Install dependencies:
see `https://docs.britive.com`
3. Configure the system to run shell and expect (TCL/TK) scripts.


## Usage
The scripts in this repository demonstrate how to:

Request temporary access to a VyOS router.
Revoke access automatically after a specified time period.
Log all access events for auditing purposes.

## Contributing
We welcome contributions! Please follow these steps:

1. Fork the repository.
2. Create a new branch for your feature or bug fix.
3. Submit a pull request with a detailed description of your changes.

## License
This project is licensed under the parent folder license structure.

## Support
For questions or support, please contact Britive Support or open an issue in this repository.
