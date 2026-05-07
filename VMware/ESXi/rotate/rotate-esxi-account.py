#!/usr/bin/env python3
"""
ESXi Local Account Rotation — Britive Access Broker

Rotates an existing local account on a standalone ESXi host via the
vSphere SOAP API at https://<host>/sdk. The account itself is not
created or removed — only its stored secret is updated.

Required environment variables:
  ESXI_HOST            IP or hostname of the target ESXi host
  ESXI_SVC_USER        Service account on the host (must hold Administrator)
  ESXI_SVC_PASSWORD    Service account secret
  ESXI_TARGET_USER     Local account whose secret will be rotated
  ESXI_NEW_PASSWORD    New secret to set on the target account

Optional:
  ESXI_VERIFY_TLS      "true" to verify TLS (default: false)

Stderr: progress log lines. Exit code 0 on success, 1 on any failure.
Secrets are never written to stdout or logs.
"""

import os
import sys
import ssl
import urllib.request
import urllib.error


def env_required(name):
    value = os.environ.get(name)
    if not value:
        print(f'[rotate] ERROR: {name} is not set', file=sys.stderr)
        sys.exit(1)
    return value


ESXI_HOST = env_required('ESXI_HOST')
ESXI_SVC_USER = env_required('ESXI_SVC_USER')
ESXI_SVC_PASSWORD = env_required('ESXI_SVC_PASSWORD')
TARGET_USER = env_required('ESXI_TARGET_USER')
NEW_PASSWORD = env_required('ESXI_NEW_PASSWORD')
VERIFY_TLS = os.environ.get('ESXI_VERIFY_TLS', 'false').lower() == 'true'


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


def esxi_update_password(cookie, username, new_password):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
  xmlns:urn="urn:vim25" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <soapenv:Body>
    <urn:UpdateUser>
      <urn:_this type="HostLocalAccountManager">ha-localacctmgr</urn:_this>
      <urn:user xsi:type="urn:HostPosixAccountSpec">
        <urn:id>{xml_escape(username)}</urn:id>
        <urn:password>{xml_escape(new_password)}</urn:password>
      </urn:user>
    </urn:UpdateUser>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(cookie, body)
    if 'Fault' in content:
        raise RuntimeError(f'UpdateUser failed: {content[:300]}')


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
    print(f'[rotate] Connecting to ESXi {ESXI_HOST}', file=sys.stderr)
    cookie = esxi_login()
    try:
        print(f'[rotate] Rotating secret for {TARGET_USER}', file=sys.stderr)
        esxi_update_password(cookie, TARGET_USER, NEW_PASSWORD)
    finally:
        esxi_logout(cookie)
    print(f'[rotate] Secret rotated successfully for {TARGET_USER}', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[rotate] ERROR: {e}', file=sys.stderr)
        sys.exit(1)
