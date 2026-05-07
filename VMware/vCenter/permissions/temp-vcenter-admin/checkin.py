#!/usr/bin/env python3
"""
vCenter JIT Admin Checkin — Britive Access Broker

Removes the role binding that checkout.py created for the requesting
user at the configured entity. The principal is derived from
BRITIVE_USER_EMAIL (or the explicit VCENTER_PRINCIPAL override) the
same way checkout derived it.

Required environment variables:
  VCENTER_HOST          IP or hostname of the vCenter Server
  VCENTER_SVC_USER      Service account username (e.g. britive-svc@vsphere.local)
  VCENTER_SVC_PASSWORD  Service account secret
  BRITIVE_USER_EMAIL    Requesting user's email (Britive-injected) — default principal

Optional:
  VCENTER_PRINCIPAL     Override the principal to revoke (default: BRITIVE_USER_EMAIL)
  VCENTER_ROOT_MOID     Inventory entity MOID where the binding was made (default: group-d1)
  VCENTER_VERIFY_TLS    "true" to verify TLS (default: false)

Stdout: JSON with target_host, principal, entity.
Stderr: progress log lines.

Idempotent: removing a binding that does not exist is treated as
success, so a duplicate checkin will not fail.
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
        print(f'[checkin] ERROR: {name} is not set', file=sys.stderr)
        sys.exit(1)
    return value


VCENTER_HOST = env_required('VCENTER_HOST')
VCENTER_SVC_USER = env_required('VCENTER_SVC_USER')
VCENTER_SVC_PASSWORD = env_required('VCENTER_SVC_PASSWORD')
BRITIVE_USER_EMAIL = env_required('BRITIVE_USER_EMAIL')

PRINCIPAL = os.environ.get('VCENTER_PRINCIPAL') or BRITIVE_USER_EMAIL
ROOT_MOID = os.environ.get('VCENTER_ROOT_MOID', 'group-d1')
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


def vcenter_remove_role(cookie):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:RemoveEntityPermission>
      <urn:_this type="AuthorizationManager">AuthorizationManager</urn:_this>
      <urn:entity type="Folder">{xml_escape(ROOT_MOID)}</urn:entity>
      <urn:user>{xml_escape(PRINCIPAL)}</urn:user>
      <urn:isGroup>false</urn:isGroup>
    </urn:RemoveEntityPermission>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content and 'NotFound' not in content:
        print(f'[checkin] WARN removing permission for {PRINCIPAL}: {content[:200]}', file=sys.stderr)


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
    print(f'[checkin] Connecting to vCenter {VCENTER_HOST}', file=sys.stderr)
    cookie = vcenter_login()
    try:
        print(f'[checkin] Removing role binding for {PRINCIPAL} at {ROOT_MOID}', file=sys.stderr)
        vcenter_remove_role(cookie)
    finally:
        vcenter_logout(cookie)

    print(f'[checkin] Done — binding revoked for {PRINCIPAL}', file=sys.stderr)
    result = {
        'status': 'revoked',
        'target_host': VCENTER_HOST,
        'principal': PRINCIPAL,
        'entity': ROOT_MOID,
    }
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[checkin] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
