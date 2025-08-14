# Windows Permission for Britive Access Broker

To assign granular privileges like `SeRemoteInteractiveLogonRight` and `SeAddUsersPrivilege` to a **Group Managed Service Account (gMSA)**, you need to use **Group Policy** or **Local Security Policy**. However, this requires some clarification:

---

## ✅ Steps to Grant `SeRemoteInteractiveLogonRight`, `SeAddUsersPrivilege`, and Remote Management Rights to a gMSA

### 🔹 1. Create or Update a GPO That Applies to Target Servers

In **Group Policy Management Console (GPMC)**:

1. Edit a GPO linked to the OU containing your Windows servers.
2. Navigate to:

   ```
   Computer Configuration →
     Policies →
       Windows Settings →
         Security Settings →
           Local Policies →
             User Rights Assignment
   ```

---

### 🔹 2. Assign the Rights

| Right                                                | Setting in GPO                          | Value to Add                                                 |
| ---------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------ |
| **Allow log on through Remote Desktop Services**     | `SeRemoteInteractiveLogonRight`         | Add: `DOMAIN\ServiceAccount$`                                          |
| **Add workstations to domain** *(not relevant here)* | `SeMachineAccountPrivilege`             | ❌ Not needed here                                            |
| **Add users to local groups (via script)**           | `SeAddUsersPrivilege`                   | Set via `SeSecurityPrivilege` or allow via custom script/GPO |
| **Access this computer from the network**            | `SeNetworkLogonRight`                   | ✅ Required for remote scripting                              |
| **Deny logon locally**                               | Ensure `DOMAIN\ServiceAccount$` is **not listed** |                                                              |

✅ Add the **gMSA name with `$` suffix**, e.g., `MYDOMAIN\svc-mgmt01$`.

> 🧠 **Note**: `SeAddUsersPrivilege` is not directly exposed in GPO—what you're really doing is **granting the gMSA permission to run a script or task** that modifies local group membership. It still needs administrative access to do that, or GPO should enforce the group membership.

---

### 🔹 3. Ensure gMSA Has Remote Access Capabilities

Make sure the ServiceAccount is allowed to:

* Be used in **services** (on domain-joined servers)
* Run **PowerShell remoting** or **WMI** commands, if applicable
* Be delegated permission to access WinRM