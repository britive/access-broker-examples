#!/usr/bin/env python3
"""
Palo Alto Networks PAN-OS XML API helpers — Britive Access Broker

Shared by the JIT admin and rotation scripts. Standard library only.
Works against a firewall or Panorama (both expose the same XML API).

Environment variables read here:
  PANOS_HOST          Firewall or Panorama management address
  PANOS_API_USER      Admin the broker authenticates as (superuser, or a custom
                      admin role with config + commit rights on mgt-config)
  PANOS_API_PASSWORD  Its password (Britive Secrets Store)
  PANOS_API_KEY       Optional. If set, used instead of generating a key
  PANOS_VERIFY_TLS    "true" to verify the management certificate (default: true)
  PANOS_CA_BUNDLE     Optional PEM bundle for a private CA
  PANOS_COMMIT_TIMEOUT  Seconds to wait for a commit job (default: 300)
"""

import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def log(msg):
    print(msg, file=sys.stderr)


def env_required(name):
    value = os.environ.get(name)
    if not value:
        log(f'ERROR: {name} is not set')
        sys.exit(1)
    return value


PANOS_HOST = env_required('PANOS_HOST')
PANOS_API_USER = env_required('PANOS_API_USER')
PANOS_API_PASSWORD = os.environ.get('PANOS_API_PASSWORD')
PANOS_API_KEY = os.environ.get('PANOS_API_KEY')
VERIFY_TLS = os.environ.get('PANOS_VERIFY_TLS', 'true').lower() != 'false'
CA_BUNDLE = os.environ.get('PANOS_CA_BUNDLE')
COMMIT_TIMEOUT = int(os.environ.get('PANOS_COMMIT_TIMEOUT', '300'))
PANOS_PORT = os.environ.get('PANOS_PORT', '443')

if not PANOS_API_KEY and not PANOS_API_PASSWORD:
    log('ERROR: set PANOS_API_PASSWORD (or PANOS_API_KEY)')
    sys.exit(1)

BASE = f'https://{PANOS_HOST}:{PANOS_PORT}/api/'

_ctx = ssl.create_default_context(cafile=CA_BUNDLE) if CA_BUNDLE else ssl.create_default_context()
if not VERIFY_TLS:
    _ctx.check_hostname = False
    _ctx.verify_mode = ssl.CERT_NONE
    log('WARNING: PANOS_VERIFY_TLS=false — TLS certificate verification is disabled')

_key = PANOS_API_KEY


def xml_escape(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
             .replace('"', '&quot;').replace("'", '&apos;'))


def _call(params, use_key=True):
    """GET /api/ with params. Returns the parsed <response> element."""
    headers = {}
    if use_key:
        headers['X-PAN-KEY'] = api_key()
    req = urllib.request.Request(BASE + '?' + urllib.parse.urlencode(params), headers=headers)
    try:
        with urllib.request.urlopen(req, context=_ctx, timeout=60) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        if not raw:
            raise RuntimeError(f'PAN-OS API HTTP {e.code}') from None
    except urllib.error.URLError as e:
        raise RuntimeError(f'PAN-OS API {PANOS_HOST}: {e.reason}') from None
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        raise RuntimeError(f'PAN-OS API returned non-XML: {raw[:200]!r}') from None
    if root.get('status') != 'success':
        msg = ''.join(root.itertext()).strip()
        raise RuntimeError(f'PAN-OS API error ({root.get("code")}): {msg[:400]}')
    return root


def api_key():
    global _key
    if _key:
        return _key
    root = _call({'type': 'keygen', 'user': PANOS_API_USER, 'password': PANOS_API_PASSWORD}, use_key=False)
    _key = root.findtext('./result/key')
    if not _key:
        raise RuntimeError('keygen returned no key')
    return _key


def op(cmd_xml):
    return _call({'type': 'op', 'cmd': cmd_xml})


def password_hash(password):
    """Ask the device to hash the password with its own algorithm/salt."""
    root = op(f'<request><password-hash><password>{xml_escape(password)}</password></password-hash></request>')
    phash = root.findtext('./result/phash')
    if not phash:
        raise RuntimeError('password-hash returned no phash')
    return phash


def admin_xpath(name):
    return f"/config/mgt-config/users/entry[@name='{xml_escape(name)}']"


def config_get(xpath):
    root = _call({'type': 'config', 'action': 'get', 'xpath': xpath})
    result = root.find('./result')
    return result if (result is not None and (result.get('total-count') or '0') != '0') else None


def config_set(xpath, element):
    _call({'type': 'config', 'action': 'set', 'xpath': xpath, 'element': element})


def config_edit(xpath, element):
    _call({'type': 'config', 'action': 'edit', 'xpath': xpath, 'element': element})


def config_delete(xpath):
    _call({'type': 'config', 'action': 'delete', 'xpath': xpath})


def role_element(role):
    """
    Build the <permissions> element for an admin role.
      superuser | superreader | panorama-admin | custom:<admin-role-profile>
    """
    if role.startswith('custom:'):
        profile = role.split(':', 1)[1]
        if not profile:
            raise RuntimeError('custom role needs a profile name: custom:<profile>')
        inner = f'<custom><profile>{xml_escape(profile)}</profile></custom>'
    elif role in ('superuser', 'superreader', 'panorama-admin'):
        inner = f'<{role}>yes</{role}>'
    else:
        raise RuntimeError(f'unsupported role "{role}"; use superuser, superreader, panorama-admin or custom:<profile>')
    return f'<permissions><role-based>{inner}</role-based></permissions>'


def commit_partial(admin=None, description='Britive'):
    """
    Commit only the changes made by `admin` (default: the API user). Returns
    the job id, or None if there was nothing to commit.
    """
    admin = admin or PANOS_API_USER
    cmd = (f'<commit><partial><admin><member>{xml_escape(admin)}</member></admin>'
           f'<description>{xml_escape(description)}</description></partial></commit>')
    root = _call({'type': 'commit', 'cmd': cmd})
    job = root.findtext('./result/job')
    if job:
        return job
    msg = ''.join(root.itertext()).strip()
    if 'no changes' in msg.lower():
        log('  Commit: no changes to commit.')
        return None
    raise RuntimeError(f'commit returned no job id: {msg[:200]}')


def wait_for_job(job_id):
    deadline = time.time() + COMMIT_TIMEOUT
    while time.time() < deadline:
        root = op(f'<show><jobs><id>{job_id}</id></jobs></show>')
        status = root.findtext('./result/job/status')
        result = root.findtext('./result/job/result')
        if status == 'FIN':
            if result != 'OK':
                details = ' '.join(t.strip() for t in root.find('./result/job').itertext() if t.strip())
                raise RuntimeError(f'commit job {job_id} finished with {result}: {details[:400]}')
            log(f'  Commit job {job_id} finished OK.')
            return
        time.sleep(3)
    raise RuntimeError(f'commit job {job_id} did not finish within {COMMIT_TIMEOUT}s')


def commit_and_wait(description):
    job = commit_partial(description=description)
    if job:
        log(f'  Commit job {job} submitted; waiting...')
        wait_for_job(job)


def emit(obj):
    """The only stdout line."""
    print(json.dumps(obj))
