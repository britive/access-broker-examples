#!/usr/bin/env python3
"""
ESXi IAM Scan — Britive Access Broker

Discovers local users and groups on a standalone ESXi host via the
vSphere SOAP API and writes a Britive Resource Manager scan report
to BROKER_INJECTED_SCAN_OUTPUT_PATH.

Required environment variables:
  ESXI_HOST                          IP or hostname of the target ESXi host
  ESXI_SVC_USER                      Service account on the host (must hold Administrator)
  ESXI_SVC_PASSWORD                  Service account password
  BROKER_INJECTED_SCAN_OUTPUT_PATH   Output file path (auto-injected by Britive)

Optional:
  ESXI_VERIFY_TLS                    "true" to verify TLS (default: false)

Output: JSON document at BROKER_INJECTED_SCAN_OUTPUT_PATH with the
shape Britive's Resource Manager expects:
  {
    "data": {"identities": [...], "groups": [...], "permissions": [], "permission_mapping": []},
    "metadata": {...}
  }

Permissions are defined in the resource type, not from this scan, so
the permissions and permission_mapping arrays are intentionally empty.
"""

import os
import re
import sys
import ssl
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone


def env_required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f'{name} is not set')
    return value


VERIFY_TLS = os.environ.get('ESXI_VERIFY_TLS', 'false').lower() == 'true'

_ssl_ctx = ssl.create_default_context()
if not VERIFY_TLS:
    _ssl_ctx.check_hostname = False
    _ssl_ctx.verify_mode = ssl.CERT_NONE


def xml_escape(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;')
             .replace('>', '&gt;').replace('"', '&quot;')
             .replace("'", '&apos;'))


def soap(host, cookie, body):
    req = urllib.request.Request(
        f'https://{host}/sdk',
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


def esxi_login(host, user, password):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Login>
      <urn:_this type="SessionManager">ha-sessionmgr</urn:_this>
      <urn:userName>{xml_escape(user)}</urn:userName>
      <urn:password>{xml_escape(password)}</urn:password>
    </urn:Login>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, cookie = soap(host, None, body)
    if 'InvalidLogin' in content or ('Fault' in content and 'LoginResponse' not in content):
        raise RuntimeError(f'ESXi login failed: {content[:300]}')
    return cookie


def esxi_logout(host, cookie):
    try:
        soap(host, cookie, '''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:Logout><urn:_this type="SessionManager">ha-sessionmgr</urn:_this></urn:Logout>
  </soapenv:Body>
</soapenv:Envelope>''')
    except Exception:
        pass


def retrieve_user_groups(host, cookie, find_users):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:vim25">
  <soapenv:Body>
    <urn:RetrieveUserGroups>
      <urn:_this type="UserDirectory">ha-user-directory</urn:_this>
      <urn:searchStr></urn:searchStr>
      <urn:exactMatch>false</urn:exactMatch>
      <urn:findUsers>{'true' if find_users else 'false'}</urn:findUsers>
      <urn:findGroups>{'false' if find_users else 'true'}</urn:findGroups>
    </urn:RetrieveUserGroups>
  </soapenv:Body>
</soapenv:Envelope>'''
    content, _ = soap(host, cookie, body)
    return content


def parse_returnvals(xml_content):
    results = []
    blocks = re.findall(r'<returnval[^>]*>(.*?)</returnval>', xml_content, re.DOTALL)
    for block in blocks:
        entry = {}
        for tag in ['principal', 'fullName', 'shellAccess', 'id', 'group', 'roleId']:
            m = re.search(rf'<{tag}>(.*?)</{tag}>', block)
            if m:
                entry[tag] = m.group(1)
        if entry:
            results.append(entry)
    return results


def write_output(path, data):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)


def main():
    output_path = env_required('BROKER_INJECTED_SCAN_OUTPUT_PATH')
    host = env_required('ESXI_HOST')
    svc_user = env_required('ESXI_SVC_USER')
    svc_password = env_required('ESXI_SVC_PASSWORD')

    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    print(f'[scan] Connecting to ESXi {host}', file=sys.stderr)

    cookie = esxi_login(host, svc_user, svc_password)
    try:
        user_xml = retrieve_user_groups(host, cookie, find_users=True)
        user_entries = parse_returnvals(user_xml)
        identities = []
        for u in user_entries:
            principal = u.get('principal', '')
            if not principal:
                continue
            identities.append({
                'id': principal,
                'name': principal,
                'type': 'User',
                'description': u.get('fullName', 'ESXi local user'),
                'created_on': now,
                'is_active': True,
                'attributes': {
                    'email': f'{principal}@{host}',
                    'first_name': u.get('fullName', principal),
                    'last_name': 'esxi',
                    'shell_access': u.get('shellAccess', 'false'),
                    'posix_id': u.get('id', ''),
                },
            })
        print(f'[scan] Found {len(identities)} user(s)', file=sys.stderr)

        group_xml = retrieve_user_groups(host, cookie, find_users=False)
        group_entries = parse_returnvals(group_xml)
        groups = []
        for g in group_entries:
            principal = g.get('principal', '')
            if not principal:
                continue
            groups.append({
                'id': principal,
                'name': principal,
                'type': 'User group',
                'description': g.get('fullName', 'ESXi local group'),
                'created_on': now,
                'is_active': True,
                'members': [],
                'attributes': {
                    'samaccountname': principal,
                },
            })
        print(f'[scan] Found {len(groups)} group(s)', file=sys.stderr)
    finally:
        esxi_logout(host, cookie)

    output = {
        'data': {
            'identities': identities,
            'groups': groups,
            'permissions': [],
            'permission_mapping': [],
        },
        'metadata': {
            'resource_id': host,
            'resource_type': 'ESXi',
            'scan_time': now,
            'scan_details': f'ESXi scan completed. Users: {len(identities)}, Groups: {len(groups)}',
            'scan_errors': '',
            'attribute_resolution': {
                'group_membership': 'id',
                'permission_mapping': 'id',
            },
        },
    }
    write_output(output_path, output)
    print(f'[scan] Output written to {output_path}', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        print(f'[scan] ERROR: {e}', file=sys.stderr)
        out = os.environ.get('BROKER_INJECTED_SCAN_OUTPUT_PATH', '')
        if out:
            error_output = {
                'data': {'identities': [], 'groups': [], 'permissions': [], 'permission_mapping': []},
                'metadata': {
                    'scan_errors': str(e),
                    'scan_time': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                },
            }
            try:
                write_output(out, error_output)
            except Exception:
                pass
        sys.exit(1)
