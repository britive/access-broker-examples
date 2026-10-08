#!/usr/bin/env python3
"""
PAN-OS — JIT Administrator Checkout — Britive Access Broker

Creates a temporary local administrator on a Palo Alto Networks firewall or
Panorama at checkout (role from the profile), commits only the broker's own
changes (`commit partial`), and returns the credential. checkin.py deletes
the administrator and commits again. No standing admin remains.

Required environment variables:
  PANOS_HOST, PANOS_API_USER, PANOS_API_PASSWORD (or PANOS_API_KEY)   see panos_api.py
  BRITIVE_USER_EMAIL     Requesting identity (Britive-injected)

Optional:
  PANOS_ROLE             superuser | superreader | panorama-admin | custom:<profile>
                         (default: superreader)
  PANOS_JIT_PREFIX       Username prefix (default: "brt-"; "" disables and then an
                         existing admin with that name makes the checkout refuse)
  PANOS_PASSWORD_LENGTH  Generated password length (default: 20)
  PANOS_VERIFY_TLS, PANOS_CA_BUNDLE, PANOS_COMMIT_TIMEOUT, PANOS_PORT

Stdout: one JSON line {"login","hostname","password","role","web_url","ssh_command"}
Stderr: progress.
"""

import os
import secrets
import string
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import panos_api as pan  # noqa: E402

EMAIL = pan.env_required('BRITIVE_USER_EMAIL')
ROLE = os.environ.get('PANOS_ROLE', 'superreader')
PREFIX = os.environ.get('PANOS_JIT_PREFIX', 'brt-')
LENGTH = int(os.environ.get('PANOS_PASSWORD_LENGTH', '20'))

# PAN-OS admin names: letters, digits, '.', '-', '_' ; max 31 chars
local = EMAIL.split('@', 1)[0]
local = ''.join(c for c in local if c.isalnum() or c in '.-_')
USERNAME = (PREFIX + local)[:31]
if not local:
    pan.log(f'ERROR: could not derive a PAN-OS admin name from {EMAIL}')
    sys.exit(1)


def gen_password(n):
    alphabet = string.ascii_letters + string.digits
    while True:
        p = ''.join(secrets.choice(alphabet) for _ in range(n))
        if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p):
            return p


def main():
    pan.log(f'Checkout: create PAN-OS admin "{USERNAME}" ({ROLE}) on {pan.PANOS_HOST} for {EMAIL}')
    perms = pan.role_element(ROLE)  # validate the role before touching the device
    xpath = pan.admin_xpath(USERNAME)

    if pan.config_get(xpath) is not None:
        if not PREFIX:
            pan.log(f'ERROR: admin "{USERNAME}" already exists and PANOS_JIT_PREFIX is empty. '
                    'Refusing to overwrite a standing administrator.')
            sys.exit(1)
        pan.log(f'  WARNING: "{USERNAME}" already exists (leftover from an earlier checkout). Refreshing in place.')

    password = gen_password(LENGTH)
    phash = pan.password_hash(password)
    # `edit` replaces the whole entry so a refreshed leftover gets exactly this role
    pan.config_edit(xpath, f'<entry name="{pan.xml_escape(USERNAME)}"><phash>{phash}</phash>{perms}</entry>')
    pan.log(f'  Candidate config updated; committing broker changes only...')
    pan.commit_and_wait(f'Britive checkout {USERNAME}')

    if pan.config_get(xpath) is None:
        pan.log(f'ERROR: "{USERNAME}" is not present after commit.')
        sys.exit(1)

    pan.emit({
        'login': USERNAME,
        'hostname': pan.PANOS_HOST,
        'password': password,
        'role': ROLE,
        'web_url': f'https://{pan.PANOS_HOST}/',
        'ssh_command': f'ssh {USERNAME}@{pan.PANOS_HOST}',
    })


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        pan.log(f'ERROR: {e}')
        sys.exit(1)
