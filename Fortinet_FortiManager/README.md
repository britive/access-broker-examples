# Introduction 

FortiManager is a centralized management platform by Fortinet that provides a single point of control for managing Fortinet network security devices, including FortiGate firewalls. It offers features for configuring, monitoring, and analyzing Fortinet appliances across an organization, enabling administrators to manage large deployments more efficiently.
Britive + FortiManager JIT Access Broker

This directory contains automation scripts that integrate Britive with Fortinet FortiManager to enable Just-In-Time (JIT) access provisioning and deprovisioning.

Britive is used as the access broker, granting time-bound privileged access. These scripts support:

    ✅ Checkout: Automatically create a temporary FortiManager user with a random JIT password.
    ✅ Check-in: Automatically log out the user (if active), delete the session, and clean up the account from FortiManager.

🛠️ How It Works
1. FortiManager_checkout.sh

    Creates a JIT user account in FortiManager using sanitized email input.
    Sets a secure temporary JIT password.
    Grants the account a pre-defined user profile.
    Output: User credentials ready to use for the duration of access in Britive UI.

2. FortiManager_checkin.sh

    Looks for any active SSH or API sessions for the user.
    Kills the session if found.
    Deletes the user account from FortiManager.
    Logs all output to a timestamped log file.

✅ Benefits

    🔐 Zero Standing Privileges: No permanent admin accounts on FortiManager.
    📜 Auditable Events: Logs each session, kill, and deletion with timestamped output.
    ⚙️ Automation-Friendly: Easily used as part of CI/CD or IDP-triggered workflows.
    ⏱️ JIT Access: Admins get access only when needed, for the duration required.

🚀 Usage

Usage is via Britive UI or Britive PyBritive CLI. Scripts should have proper exection permissions.

chmod +x FortiManager_checkin.sh

Following must be chages as per your setup

    fmg_host="IP"
    fmg_admin_user="FortiManager_Svc_Account"
    fmg_admin_password="********"
    jit_username="will be coming from Britive automatically"

Pull requests are welcome! If you’re using Britive and Fortinet in your org, feel free to open issues or suggest improvements.


### User Experience ###

Using CLI first login to Britive tenant called "se-learn" 

<pre> $ pybritive login -t se-learn

Performing interactive login against tenant se-learn.
Authenticated to tenant se-learn via interactive login. </pre>

Now run command to see the profiles

<pre> $ pybritive ls profiles -t se-learn </pre>

<pre> $ pybritive ls profiles -t se-learn | Grep "FortiManager Standard"
    "Profile": "FortiManager Standard User Profile",
    "Name": "Resources/Fortinet_FortiManager/FortiManager Standard User Profile" </pre>


<pre> $ pybritive checkout "Resources/Fortinet_FortiManager/FortiManager Standard User Profile" -t se-learn

.......
Successfully received JIT user information about shahzad.ali@britive.com from Britive tenant.
JIT user shahzadali configured successfully with 'FortiManager Standard_User' profile.
Run ssh shahzadali@18.144.170.42 command with 3noUtu1V1PG4hHLCiiSwHg password to login </pre>


<pre> $ ssh shahzadali@18.144.170.42 </pre>


It is very restriced user and can only execute following commands

<pre>
config fmupdate web-spam fgd-setting
config fmupdate fds-setting
config fmupdate fwm-setting

</pre>

All other commands are blocked. 

<pre> 

FortiManager-shahzad $ show
#config-version=FMG-VM64-AWSOnDemand-7.6-FW-build3344-241023
#branch_pt=3344

No permission to 'show system.global'
No permission to 'show system.interface'
No permission to 'show system.web-proxy'
No permission to 'show system.local-in-policy'
No permission to 'show system.local-in-policy6'
No permission to 'show system.snmp.sysinfo'
No permission to 'show system.snmp.community'
No permission to 'show system.snmp.user'
No permission to 'show system.route'
No permission to 'show system.route6'
No permission to 'show system.dns'
No permission to 'show system.connector'

</pre>

After the job is done, checkin the profile 

<pre>$ pybritive checkin "Resources/Fortinet_FortiManager/FortiManager Standard User Profile" -t se-learn </pre>

MIT License. See LICENSE for more details.
