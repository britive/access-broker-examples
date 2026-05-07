#!/usr/bin/env python3
"""
vCenter JIT Admin Checkout — Britive Access Broker

Grants a role (default: Administrator) at the vCenter root folder to an
existing identity (the requestor's SSO/AD principal). No local account
is created — the requestor signs in to vCenter with their usual
identity and finds the role granted until checkin.

Required environment variables:
  VCENTER_HOST          IP or hostname of the vCenter Server
  VCENTER_SVC_USER      Service account username (e.g. britive-svc@vsphere.local)
  VCENTER_SVC_PASSWORD  Service account secret
  BRITIVE_USER_EMAIL    Requesting user's email (Britive-injected) — default principal to elevate

Optional:
  VCENTER_PRINCIPAL     Override the principal to elevate (default: BRITIVE_USER_EMAIL)
  VCENTER_ROLE_ID       Role ID to grant (default: -1, built-in Administrator)
  VCENTER_ROOT_MOID     Inventory entity MOID to grant at (default: group-d1, vCenter root folder)
  VCENTER_PROPAGATE     "true"/"false" — whether the role propagates to children (default: true)
  VCENTER_VERIFY_TLS    "true" to verify TLS (default: false)

Stdout: JSON with target_host, access_url, principal, role_id, entity.
Stderr: progress log lines.
"""

import os
import sys
import ssl
import json
import urllib.request
import urllib.error


def env_required(name):
    value = os.environ.get(name)
    if not value:
        print(f'[checkout] ERROR: {name} is not set', file=sys.stderr)
        sys.exit(1)
    return value


VCENTER_HOST = env_required('VCENTER_HOST')
VCENTER_SVC_USER = env_required('VCENTER_SVC_USER')
VCENTER_SVC_PASSWORD = env_required('VCENTER_SVC_PASSWORD')
BRITIVE_USER_EMAIL = env_required('BRITIVE_USER_EMAIL')

PRINCIPAL = os.environ.get('VCENTER_PRINCIPAL') or BRITIVE_USER_EMAIL
ROLE_ID = int(os.environ.get('VCENTER_ROLE_ID', '-1'))
ROOT_MOID = os.environ.get('VCENTER_ROOT_MOID', 'group-d1')
PROPAGATE = os.environ.get('VCENTER_PROPAGATE', 'true').lower() == 'true'
VERIFY_TLS = os.environ.get('VCENTER_VERIFY_TLS', 'false').lower() == 'true'


_ssl_ctx = ssl.create_default_context()
if not VERIFY_TLS:
    _ssl_ctx.check_hostname = False
    _ssl_ctx.verify_mode = ssl.CERT_NONE


def xml_escape(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;')
             .replace("'", '&apos;'))


def soap(cookie, body):
    req = urllib.request.Request(
        f'https://{VCENTER_HOST}/sdk',
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


def vcenter_login():
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Login>
      <urn:_this type="SessionManager">SessionManager</urn:_this>
      <urn:userName>{xml_escape(VCENTER_SVC_USER)}</urn:userName>
      <urn:password>{xml_escape(VCENTER_SVC_PASSWORD)}</urn:password>
    </urn:Login>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, cookie = soap(None, body)
    if 'InvalidLogin' in content or ('Fault' in content and 'LoginResponse' not in content):
        raise RuntimeError(f'vCenter login failed: {content[:300]}')
    return cookie


def vcenter_assign_role(cookie):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:SetEntityPermissions>
      <urn:_this type="AuthorizationManager">AuthorizationManager</urn:_this>
      <urn:entity type="Folder">{xml_escape(ROOT_MOID)}</urn:entity>
      <urn:permission>
        <urn:principal>{xml_escape(PRINCIPAL)}</urn:principal>
        <urn:group>false</urn:group>
        <urn:roleId>{ROLE_ID}</urn:roleId>
        <urn:propagate>{'true' if PROPAGATE else 'false'}</urn:propagate>
      </urn:permission>
    </urn:SetEntityPermissions>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content:
        raise RuntimeError(f'SetEntityPermissions failed: {content[:300]}')


def vcenter_logout(cookie):
    try:
        soap(cookie, '''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Logout><urn:_this type="SessionManager">SessionManager</urn:_this></urn:Logout>
  </soapenv:Body>
</soapenv:Envelope>''')
    except Exception:
        pass


def main():
    access_url = f'https://{VCENTER_HOST}/ui'

    print(f'[checkout] Connecting to vCenter {VCENTER_HOST}', file=sys.stderr)
    cookie = vcenter_login()
    try:
        print(f'[checkout] Granting role {ROLE_ID} to {PRINCIPAL} at {ROOT_MOID}', file=sys.stderr)
        vcenter_assign_role(cookie)
    finally:
        vcenter_logout(cookie)
    print(f'[checkout] {PRINCIPAL} elevated', file=sys.stderr)

    result = {
        'status': 'checked_out',
        'target_host': VCENTER_HOST,
        'access_url': access_url,
        'principal': PRINCIPAL,
        'role_id': ROLE_ID,
        'entity': ROOT_MOID,
        'note': (f'Sign in to vCenter at {access_url} with your usual identity. '
                 f'The role is granted until checkin.'),
    }
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[checkout] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
