#!/usr/bin/env python3
"""
ESXi JIT Local Admin Checkout — Britive Access Broker

Creates an ephemeral local account on a standalone ESXi host, grants the
Administrator role at the root, and returns the host UI URL, an SSH
command, and the temporary credentials. The JIT account exists only
until checkin removes it.

The JIT account name is the requestor's email local part — e.g.
jane.doe@example.com becomes "jane.doe". The same account
works for both the host web UI and SSH (created with shellAccess=true).

All API calls go to the vSphere SOAP endpoint at https://<host>/sdk.

Required environment variables:
  ESXI_HOST            IP or hostname of the target ESXi host
  ESXI_SVC_USER        Service account on the host (must hold Administrator)
  ESXI_SVC_PASSWORD    Service account secret
  BRITIVE_USER_EMAIL   Requesting user's email (Britive-injected)

Optional:
  ESXI_VERIFY_TLS      "true" to verify TLS (default: false — most ESXi hosts use self-signed certs)

Stdout: JSON with target_host, access_url, ssh_command, username, password.
Stderr: progress log lines.
"""

import os
import re
import sys
import ssl
import json
import random
import string
import urllib.request
import urllib.error


def env_required(name):
    value = os.environ.get(name)
    if not value:
        print(f'[checkout] ERROR: {name} is not set', file=sys.stderr)
        sys.exit(1)
    return value


ESXI_HOST = env_required('ESXI_HOST')
ESXI_SVC_USER = env_required('ESXI_SVC_USER')
ESXI_SVC_PASSWORD = env_required('ESXI_SVC_PASSWORD')
BRITIVE_USER_EMAIL = env_required('BRITIVE_USER_EMAIL')
VERIFY_TLS = os.environ.get('ESXI_VERIFY_TLS', 'false').lower() == 'true'


_ssl_ctx = ssl.create_default_context()
if not VERIFY_TLS:
    _ssl_ctx.check_hostname = False
    _ssl_ctx.verify_mode = ssl.CERT_NONE


def random_password(length=18):
    chars = string.ascii_letters + string.digits + '!@#$%^&*'
    return ''.join(random.SystemRandom().choice(chars) for _ in range(length))


def jit_username(email):
    """Use the email local part as the local account name, sanitized to ESXi-safe characters."""
    local = email.split('@')[0].lower()
    safe = re.sub(r'[^a-z0-9._-]', '', local)
    return safe or 'britive-jit-user'


def xml_escape(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;')
             .replace("'", '&apos;'))


def soap(cookie, body):
    req = urllib.request.Request(
        f'https://{ESXI_HOST}/sdk',
        data=body.strip().encode('utf-8'),
        method='POST',
    )
    req.add_header('Content-Type', 'text/xml; charset=utf-8')
    if cookie:
        req.add_header('Cookie', cookie)
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=30) as r:
            return r.read().decode('utf-8'), r.headers.get('Set-Cookie', '')
    except urllib.error.HTTPError as e:
        return e.read().decode('utf-8'), ''


def esxi_login():
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Login>
      <urn:_this type="SessionManager">ha-sessionmgr</urn:_this>
      <urn:userName>{xml_escape(ESXI_SVC_USER)}</urn:userName>
      <urn:password>{xml_escape(ESXI_SVC_PASSWORD)}</urn:password>
    </urn:Login>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, cookie = soap(None, body)
    if 'InvalidLogin' in content or ('Fault' in content and 'LoginResponse' not in content):
        raise RuntimeError(f'ESXi login failed: {content[:300]}')
    return cookie


def esxi_create_user(cookie, username, password, description):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
  xmlns:urn="urn:vim25" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <soapenv:Body>
    <urn:CreateUser>
      <urn:_this type="HostLocalAccountManager">ha-localacctmgr</urn:_this>
      <urn:user xsi:type="urn:HostPosixAccountSpec">
        <urn:id>{xml_escape(username)}</urn:id>
        <urn:password>{xml_escape(password)}</urn:password>
        <urn:description>{xml_escape(description)}</urn:description>
        <urn:shellAccess>true</urn:shellAccess>
      </urn:user>
    </urn:CreateUser>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content:
        if 'AlreadyExists' in content:
            print(f'[checkout] User {username} exists — updating password', file=sys.stderr)
            esxi_update_user(cookie, username, password)
        else:
            raise RuntimeError(f'CreateUser failed: {content[:300]}')


def esxi_update_user(cookie, username, password):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
  xmlns:urn="urn:vim25" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <soapenv:Body>
    <urn:UpdateUser>
      <urn:_this type="HostLocalAccountManager">ha-localacctmgr</urn:_this>
      <urn:user xsi:type="urn:HostPosixAccountSpec">
        <urn:id>{xml_escape(username)}</urn:id>
        <urn:password>{xml_escape(password)}</urn:password>
      </urn:user>
    </urn:UpdateUser>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content:
        raise RuntimeError(f'UpdateUser failed: {content[:300]}')


def esxi_assign_admin(cookie, username):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:SetEntityPermissions>
      <urn:_this type="AuthorizationManager">ha-authmgr</urn:_this>
      <urn:entity type="Folder">ha-folder-root</urn:entity>
      <urn:permission>
        <urn:principal>{xml_escape(username)}</urn:principal>
        <urn:group>false</urn:group>
        <urn:roleId>-1</urn:roleId>
        <urn:propagate>true</urn:propagate>
      </urn:permission>
    </urn:SetEntityPermissions>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content:
        raise RuntimeError(f'SetEntityPermissions failed: {content[:300]}')


def esxi_logout(cookie):
    try:
        soap(cookie, '''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Logout><urn:_this type="SessionManager">ha-sessionmgr</urn:_this></urn:Logout>
  </soapenv:Body>
</soapenv:Envelope>''')
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Optional extension: enable the SSH service on the host at checkout time.
#
# UNTESTED in this template. The JIT account is already created with
# shellAccess=true, so SSH will work once the host's TSM-SSH service is
# running. SSH is disabled by default on ESXi. To have checkout start it
# automatically, uncomment esxi_start_ssh_service() below and the call
# site in main(), and gate it with the ESXI_ENABLE_SSH env var (default
# false).
#
# Caveats:
#   - The service account must hold Host.Config.Settings in addition to
#     the user/permission privileges it already needs.
#   - The HostServiceSystem MOID 'serviceSystem' is the standard for
#     standalone ESXi but verify against your host before relying on it.
#   - Consider whether checkin should put SSH back to its prior state
#     (read it before starting, persist somewhere, stop on checkin if it
#     was off). Not modeled here.
#
# def esxi_start_ssh_service(cookie):
#     body = '''<?xml version="1.0" encoding="UTF-8"?>
# <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
#   <soapenv:Body>
#     <urn:StartService>
#       <urn:_this type="HostServiceSystem">serviceSystem</urn:_this>
#       <urn:id>TSM-SSH</urn:id>
#     </urn:StartService>
#   </soapenv:Body>
# </soapenv:Envelope>'''
#     content, _ = soap(cookie, body)
#     if 'Fault' in content and 'AlreadyRunning' not in content:
#         raise RuntimeError(f'StartService(TSM-SSH) failed: {content[:300]}')
# ---------------------------------------------------------------------------


def main():
    jit_user = jit_username(BRITIVE_USER_EMAIL)
    jit_pass = random_password()
    access_url = f'https://{ESXI_HOST}/ui'

    print(f'[checkout] Connecting to ESXi {ESXI_HOST}', file=sys.stderr)
    cookie = esxi_login()
    try:
        print(f'[checkout] Creating JIT user {jit_user}', file=sys.stderr)
        esxi_create_user(cookie, jit_user, jit_pass,
                         f'Britive JIT — {BRITIVE_USER_EMAIL}')
        esxi_assign_admin(cookie, jit_user)
        # if os.environ.get('ESXI_ENABLE_SSH', 'false').lower() == 'true':
        #     esxi_start_ssh_service(cookie)
    finally:
        esxi_logout(cookie)
    print(f'[checkout] {jit_user} created with Administrator role', file=sys.stderr)

    result = {
        'status': 'checked_out',
        'target_host': ESXI_HOST,
        'access_url': access_url,
        'ssh_command': f'ssh {jit_user}@{ESXI_HOST}',
        'username': jit_user,
        'password': jit_pass,
        'note': (f'Open {access_url} and sign in with the credentials above, '
                 f'or use SSH if the SSH service is enabled on the host.'),
    }
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[checkout] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
