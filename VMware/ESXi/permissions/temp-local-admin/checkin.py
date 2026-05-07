#!/usr/bin/env python3
"""
ESXi JIT Local Admin Checkin — Britive Access Broker

Removes the JIT account that checkout.py created for the requesting user.
The account name is derived from BRITIVE_USER_EMAIL the same way checkout
derived it: the lowercase email local part, sanitized to ESXi-safe chars.

All API calls go to the vSphere SOAP endpoint at https://<host>/sdk.

Required environment variables:
  ESXI_HOST            IP or hostname of the target ESXi host
  ESXI_SVC_USER        Service account on the host (must hold Administrator)
  ESXI_SVC_PASSWORD    Service account secret
  BRITIVE_USER_EMAIL   Requesting user's email (Britive-injected)

Optional:
  ESXI_VERIFY_TLS      "true" to verify TLS (default: false)

Stdout: JSON with target_host and the removed account.
Stderr: progress log lines.

Idempotent: removing an account or permission that does not exist is
treated as success, so a duplicate checkin will not fail.
"""

import os
import re
import sys
import ssl
import json
import urllib.request
import urllib.error


def env_required(name):
    value = os.environ.get(name)
    if not value:
        print(f'[checkin] ERROR: {name} is not set', file=sys.stderr)
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


def jit_username(email):
    """Mirror checkout.py: email local part, lowercased, ESXi-safe characters only."""
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


def esxi_remove_permission(cookie, username):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:RemoveEntityPermission>
      <urn:_this type="AuthorizationManager">ha-authmgr</urn:_this>
      <urn:entity type="Folder">ha-folder-root</urn:entity>
      <urn:user>{xml_escape(username)}</urn:user>
      <urn:isGroup>false</urn:isGroup>
    </urn:RemoveEntityPermission>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content and 'NotFound' not in content:
        print(f'[checkin] WARN removing permission for {username}: {content[:200]}', file=sys.stderr)


def esxi_remove_user(cookie, username):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:RemoveUser>
      <urn:_this type="HostLocalAccountManager">ha-localacctmgr</urn:_this>
      <urn:userName>{xml_escape(username)}</urn:userName>
    </urn:RemoveUser>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content and 'NotFound' not in content and 'UserNotFound' not in content:
        print(f'[checkin] WARN removing user {username}: {content[:200]}', file=sys.stderr)


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


def main():
    jit_user = jit_username(BRITIVE_USER_EMAIL)

    print(f'[checkin] Connecting to ESXi {ESXI_HOST}', file=sys.stderr)
    cookie = esxi_login()
    try:
        print(f'[checkin] Removing {jit_user}', file=sys.stderr)
        esxi_remove_permission(cookie, jit_user)
        esxi_remove_user(cookie, jit_user)
    finally:
        esxi_logout(cookie)

    print(f'[checkin] Done — {jit_user} removed', file=sys.stderr)
    result = {
        'status': 'revoked',
        'target_host': ESXI_HOST,
        'removed_user': jit_user,
    }
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[checkin] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
