# Endpoint Privilege Management (EPM)

Scripts for Britive's **Endpoint Privilege Management** integrations, which extend Zero Standing Privileges to user workstations by removing standing local administrator rights and granting elevation just in time.

## How these differ from the rest of this repository

Everything else here is an **Access Broker** permission: the broker runs `checkout` / `checkin` on a target resource, reading its inputs from environment variables.

EPM scripts are not broker permissions. They are executed by the **endpoint agent vendor** — for CrowdStrike, through Falcon Real Time Response (RTR) — and Britive invokes them through the vendor's API. They run as SYSTEM (Windows) or root (macOS) on the user's own workstation, take command-line parameters rather than environment variables, and never touch a broker.

Keep that distinction in mind when reading: nothing in this directory requires a broker to be installed.

## Contents

| Directory | Vendor | Status |
| --- | --- | --- |
| [`CrowdStrike/`](CrowdStrike/) | CrowdStrike Falcon (RTR) | Available |

Microsoft Defender EPM support is planned; its scripts will land beside CrowdStrike when it ships.

## Documentation

Setup guides for these scripts are on the Britive Learn portal under **Endpoint Privilege Management**.
