# Broker Install on Linux servers

## Redhat (RHEL)

    ```bash
    ## Download broker bits from Britive
    curl -O "<Broker Dowonload Link>"
    ##Install and verify JDK
    sudo dnf install java-21-openjdk-devel
    java --version
    ##Install and configure Britive Broker
    sudo rpm -ivh britive-broker-1.0.0.rpm
    cd /opt
    sudo chown -R britivebroker:britivebroker britive-broker
    ## Update Broker configuration
    cd /opt/britive-broker/config/
    cp broker-config-template.yml broker-config.yml
    vi broker-config.yml
    # Set permission and start broker service
    cd /opt
    sudo chown -R britivebroker:britivebroker britive-broker
    sudo systemctl start britive-broker
    ```

## Ubuntu

## Amazon Linux
