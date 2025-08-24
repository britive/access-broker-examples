# Broker Install on Linux servers

## Redhat (RHEL)

```bash

curl -O "<Broker Dowonload Link>"

sudo dnf install java-21-openjdk-devel

java --version

sudo rpm -ivh britive-broker-1.0.0.rpm

cd /opt

sudo chown -R britivebroker:britivebroker britive-broker

cd /opt/britive-broker/config/

cd broker-config-template.yml broker-config.yml

vi broker-config.yml

cd /opt

sudo chown -R britivebroker:britivebroker britive-broker

sudo systemctl start britive-broker


```


## Ubuntu


## Amazon Linux