#!/usr/bin/env python3
"""
PAN-OS — Rotate a local administrator's password — Britive Access Broker

Sets a new password on an existing firewall or Panorama administrator (for
example the built-in `admin`) and commits only the broker's own change.
Role and other settings are untouched. Wire as both checkout and checkin
script for a break-glass profile: checkout returns the new secret to the
user; checkin rotates again and returns it to the broker for the Secrets
Store.

Required environment variables:
  PANOS_HOST, PANOS_API_USER, PANOS_API_PASSWORD (or PANOS_API_KEY)
  PANOS_TARGET_USER      Administrator to rotate (e.g. "admin"). May be the
                         API user itself (self-rotation); the API key obtained
                         before the change stays valid for this run.
Optional:
  PANOS_NEW_PASSWORD     Supply only if another system owns the value
  PANOS_PASSWORD_LENGTH  Generated length (default 20)
  PANOS_VERIFY_TLS, PANOS_CA_BUNDLE, PANOS_COMMIT_TIMEOUT, PANOS_PORT

Stdout: one JSON line {"login","hostname","password","web_url"}
Stderr: progress.
"""

import os
import secrets
import string
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'permissions', 'jit-admin'))
import panos_api as pan  # noqa: E402

TARGET = pan.env_required('PANOS_TARGET_USER')
LENGTH = int(os.environ.get('PANOS_PASSWORD_LENGTH', '20'))


def gen_password(n):
    alphabet = string.ascii_letters + string.digits
    while True:
        p = ''.join(secrets.choice(alphabet) for _ in range(n))
        if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p):
            return p


def main():
    pan.log(f'Rotating PAN-OS admin "{TARGET}" on {pan.PANOS_HOST}')
    xpath = pan.admin_xpath(TARGET)
    if pan.config_get(xpath) is None:
        pan.log(f'ERROR: administrator "{TARGET}" does not exist (rotation never creates accounts)')
        sys.exit(1)

    password = os.environ.get('PANOS_NEW_PASSWORD') or gen_password(LENGTH)
    phash = pan.password_hash(password)
    # Set only the phash node so the role/permissions stay exactly as they were
    pan.config_set(xpath, f'<phash>{phash}</phash>')
    pan.commit_and_wait(f'Britive rotate {TARGET}')

    pan.emit({
        'login': TARGET,
        'hostname': pan.PANOS_HOST,
        'password': password,
        'web_url': f'https://{pan.PANOS_HOST}/',
    })


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        pan.log(f'ERROR: {e}')
        sys.exit(1)
