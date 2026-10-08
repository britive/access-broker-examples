#!/usr/bin/env python3
"""
Cisco ISE ERS helpers — Britive Access Broker

Shared by checkout.py / checkin.py in this directory. Standard library only.

Environment variables read here:
  ISE_HOST            ISE PAN hostname or IP (ERS is served by the Primary Admin Node)
  ISE_ERS_USER        ERS admin username (ISE admin with the "ERS Admin" or
                      "Super Admin" group; ERS must be enabled under
                      Administration > System > Settings > API Settings)
  ISE_ERS_PASSWORD    Its password (Britive Secrets Store)
  ISE_ERS_PORT        ERS port (default: 9060)
  ISE_VERIFY_TLS      "true" to verify the ISE certificate (default: true).
                      Set "false" only for lab appliances with self-signed certs.
  ISE_CA_BUNDLE       Optional PEM bundle for a private CA
"""

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


def log(msg):
    print(msg, file=sys.stderr)


def env_required(name):
    value = os.environ.get(name)
    if not value:
        log(f'ERROR: {name} is not set')
        sys.exit(1)
    return value


ISE_HOST = env_required('ISE_HOST')
ISE_ERS_USER = env_required('ISE_ERS_USER')
ISE_ERS_PASSWORD = env_required('ISE_ERS_PASSWORD')
ISE_ERS_PORT = os.environ.get('ISE_ERS_PORT', '9060')
VERIFY_TLS = os.environ.get('ISE_VERIFY_TLS', 'true').lower() != 'false'
CA_BUNDLE = os.environ.get('ISE_CA_BUNDLE')

BASE = f'https://{ISE_HOST}:{ISE_ERS_PORT}/ers/config'

_ctx = ssl.create_default_context(cafile=CA_BUNDLE) if CA_BUNDLE else ssl.create_default_context()
if not VERIFY_TLS:
    _ctx.check_hostname = False
    _ctx.verify_mode = ssl.CERT_NONE
    log('WARNING: ISE_VERIFY_TLS=false — TLS certificate verification is disabled')

_auth = base64.b64encode(f'{ISE_ERS_USER}:{ISE_ERS_PASSWORD}'.encode()).decode()


def ers(method, path, body=None):
    """Call the ERS API. Returns (status, parsed JSON or None)."""
    req = urllib.request.Request(BASE + path, method=method)
    req.add_header('Authorization', f'Basic {_auth}')
    req.add_header('Accept', 'application/json')
    if body is not None:
        req.add_header('Content-Type', 'application/json')
        req.data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, context=_ctx, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors='replace')
        raise RuntimeError(f'ERS {method} {path} -> HTTP {e.code}: {raw[:400]}') from None
    except urllib.error.URLError as e:
        raise RuntimeError(f'ERS {method} {path} -> {e.reason}') from None


def find_internal_user(name):
    """Return the full internaluser object for `name`, or None."""
    q = urllib.parse.quote(f'name.EQ.{name}', safe='.')
    _, data = ers('GET', f'/internaluser?filter={q}')
    resources = (data or {}).get('SearchResult', {}).get('resources', [])
    if not resources:
        return None
    user_id = resources[0]['id']
    _, data = ers('GET', f'/internaluser/{user_id}')
    return data['InternalUser']


def find_identity_group_id(name):
    q = urllib.parse.quote(f'name.EQ.{name}', safe='.')
    _, data = ers('GET', f'/identitygroup?filter={q}')
    resources = (data or {}).get('SearchResult', {}).get('resources', [])
    if not resources:
        raise RuntimeError(f"Identity group '{name}' not found in ISE")
    return resources[0]['id']


def set_user_groups(user, group_ids):
    """PUT the user back with a new identityGroups list (comma-separated IDs).

    The full object from GET is sent back (minus the read-only `link`) so that
    enabled/email/customAttributes etc. are preserved; ERS treats PUT as a
    replace. The password is never returned by GET and is left untouched when
    omitted.
    """
    payload = {k: v for k, v in user.items() if k != 'link'}
    payload['identityGroups'] = ','.join(group_ids)
    ers('PUT', f"/internaluser/{user['id']}", {'InternalUser': payload})


def emit(obj):
    """The only stdout line."""
    print(json.dumps(obj))
