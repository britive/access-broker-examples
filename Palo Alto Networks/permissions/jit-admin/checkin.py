#!/usr/bin/env python3
"""
PAN-OS — JIT Administrator Checkin — Britive Access Broker

Deletes the temporary administrator created by checkout.py, commits the
broker's changes, and verifies it is gone. Idempotent; retries once.

Required environment variables:
  PANOS_HOST, PANOS_API_USER, PANOS_API_PASSWORD (or PANOS_API_KEY)
  BRITIVE_USER_EMAIL
Optional:
  PANOS_JIT_PREFIX (default "brt-"), PANOS_CHECKIN_RETRIES (default 1),
  PANOS_VERIFY_TLS, PANOS_CA_BUNDLE, PANOS_COMMIT_TIMEOUT, PANOS_PORT

Stdout: nothing. Stderr: progress.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import panos_api as pan  # noqa: E402

EMAIL = pan.env_required('BRITIVE_USER_EMAIL')
PREFIX = os.environ.get('PANOS_JIT_PREFIX', 'brt-')
RETRIES = int(os.environ.get('PANOS_CHECKIN_RETRIES', '1'))

local = ''.join(c for c in EMAIL.split('@', 1)[0] if c.isalnum() or c in '.-_')
USERNAME = (PREFIX + local)[:31]


def remove():
    xpath = pan.admin_xpath(USERNAME)
    if pan.config_get(xpath) is None:
        pan.log(f'  "{USERNAME}" is not in the candidate config; checking the running config via commit anyway.')
    else:
        pan.config_delete(xpath)
        pan.log(f'  Deleted "{USERNAME}" from candidate config.')
    pan.commit_and_wait(f'Britive checkin {USERNAME}')
    if pan.config_get(xpath) is not None:
        raise RuntimeError(f'"{USERNAME}" is still present after commit')
    # Terminate any session the account still holds (admins can stay logged in after deletion)
    try:
        pan.op('<request><logout><admin>' + pan.xml_escape(USERNAME) + '</admin></logout></request>')
    except RuntimeError as e:
        pan.log(f'  (session logout not applicable: {e})')


def main():
    pan.log(f'Checkin: remove PAN-OS admin "{USERNAME}" on {pan.PANOS_HOST}')
    attempt = 0
    while True:
        try:
            remove()
            pan.log(f'  Removed "{USERNAME}".')
            return
        except RuntimeError as e:
            attempt += 1
            if attempt > RETRIES:
                pan.log(f'ERROR: checkin FAILED after {attempt} attempt(s): {e}. '
                        f'Remove manually: Device > Administrators > {USERNAME}, then commit.')
                sys.exit(1)
            pan.log(f'  attempt {attempt} failed ({e}); retrying in 5s...')
            time.sleep(5)


if __name__ == '__main__':
    main()
