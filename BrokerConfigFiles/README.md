---

# 📘 Directory Summary

This directory includes several examples of the broker configuration file that allows the Britive broker to start, bootstrap and begin receiving checkout/in requests.
Examples include:
- Configuration to just get the broker up and running.
- Configuration to use token and name generator scripts to fetch essential information from remote location or vault.
- Configuration options when running broker scripts locally vs remotely


## 📄 README

### 📂 Files Included

| File                          | Purpose                                                                                       |
| ------------------------------|-----------------------------------------------------------------------------------------------|
| minimum_broker-config.yml     | Minimum configuration required to bootstrap the broker the host britive tenant.               |
| no_token_broker-config.yml    | Minimum requirement for non-test configuration with token being fetched via a script.         |
| proxy_broker-config.yml       | Broker configuration with a proxy. Broker will use the configured proxy information.          |
| single_broker-config.yml      | Broker configuration that support single Resource Type and multiple permissions for the same. |
| template_broker-config.yml    | Full broker template. This is also shipped with every broker install.                         |

---