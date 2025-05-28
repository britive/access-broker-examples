# Installing Apache Guacamole on Windows using Docker

This guide walks you through the process of installing and running Apache Guacamole on a Windows Server using Docker. Apache Guacamole is a clientless remote desktop gateway that supports RDP, VNC, and SSH.

## Prerequisites

* **Windows Server 2019 or 2022** (GUI version recommended)
* **Administrator privileges**
* **Internet access** on the server
* **Docker installed** (Docker Desktop or Docker Engine)
* **Firewall ports open**:

  * `8080` for Guacamole web interface
  * `4822` for guacd daemon
  * `3389` for RDP (ensure it's open to target VMs)

---

## Step 1: Install Docker on Windows Server

### 1.1 Enable Containers and Hyper-V

Run PowerShell as Administrator:

    ```powershell
    Install-WindowsFeature -Name containers
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
    ```

> Your server will restart after this step.

### 1.2 Install Docker

1. Download Docker from: [https://docs.docker.com/docker-for-windows/install/](https://docs.docker.com/docker-for-windows/install/)
2. Choose Docker Desktop (for WSL2) or Docker Engine (if GUI-less).
3. Run the installer and follow the prompts.
4. After installation, verify Docker is working:

    ```powershell
    docker --version
    ```

---

## Step 2: Create Docker Compose Configuration

### 2.1 Create a Working Directory

    ```powershell
    mkdir C:\Guacamole
    cd C:\Guacamole
    ```

### 2.2 Create `docker-compose.yml`

Save the following content into `C:\Guacamole\docker-compose.yml`:

```yaml
version: '2'

services:
  guacd:
    image: guacamole/guacd
    container_name: guacd
    restart: always

  guacamole:
    image: guacamole/guacamole
    container_name: guacamole
    restart: always
    ports:
      - "8080:8080"
    links:
      - guacd
      - mysql
    environment:
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacamole_user
      MYSQL_PASSWORD: some_password
      MYSQL_HOSTNAME: mysql

  mysql:
    image: mysql:5.7
    container_name: guac_mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: root_password
      MYSQL_DATABASE: guacamole_db
      MYSQL_USER: guacamole_user
      MYSQL_PASSWORD: some_password
    volumes:
      - mysql_data:/var/lib/mysql

volumes:
  mysql_data:
```

> Replace `some_password` and `root_password` with strong secrets.

---

## Step 3: Initialize the Guacamole Database

### 3.1 Download JDBC Auth Extension

1. Download the JDBC extension from the [Guacamole Releases page](https://guacamole.apache.org/releases/):

   * `guacamole-auth-jdbc-1.5.4.tar.gz`
2. Extract the archive.
3. Locate the SQL schema file: `mysql/schema/001-create-schema.sql`

### 3.2 Apply Schema to MySQL Container

```powershell
docker cp .\schema\001-create-schema.sql guac_mysql:/001-create-schema.sql
docker exec -it guac_mysql bash
```

Inside the container:

```bash
mysql -u root -p guacamole_db < /001-create-schema.sql
```

Enter the `root_password` when prompted, then exit:

```bash
exit
```

---

## Step 4: Start the Guacamole Stack

In PowerShell:

```powershell
cd C:\Guacamole
docker-compose up -d
```

Check container status:

```powershell
docker ps
```

Access the UI in your browser:

```html
http://<your-windows-server-ip>:8080/guacamole
```

Default credentials:

* **Username**: `guacadmin`
* **Password**: `guacadmin`

Change the password after logging in.

---

## Step 5: Add RDP Connections

1. Go to Settings > Connections > New Connection

2. Fill in the details:

   * Name: `My Windows VM`
   * Protocol: `RDP`
   * Hostname: `<target-vm-ip>`
   * Port: `3389`
   * Username/Password or prompt at connection

3. Optionally configure:

   * Enable clipboard
   * Drive redirection
   * Security mode (e.g., NLA)

Save the connection.

---

## Maintenance Tips

* Restart stack: `docker-compose restart`
* Pull updates: `docker-compose pull && docker-compose up -d`
* View logs:

  ```powershell
  docker logs guacamole
  docker logs guacd
  ```

* Backup MySQL:

  ```powershell
  docker exec guac_mysql mysqldump -u root -p guacamole_db > guacamole_backup.sql
  ```

---

## Optional: Enable LDAP or SAML Auth

1. Download the appropriate auth extension from [Apache Guacamole](https://guacamole.apache.org/releases/).
2. Mount the `.jar` file in the container's `GUACAMOLE_HOME/extensions`.
3. Configure `guacamole.properties` via mounted volume.

---

## Done

You now have a working Apache Guacamole setup on Windows using Docker. You can manage RDP connections to Windows VMs securely and centrally through a browser.
