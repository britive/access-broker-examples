#!/usr/bin/env python3
"""
Cisco ISE — Identity Group Checkout (AAA-driven elevation) — Britive Access Broker

Adds an existing ISE **internal user** to an ISE identity group at checkout.
ISE Device Administration (TACACS+) or Network Access (RADIUS) policy maps the
group to a shell profile / command set / authorization profile, so the user is
elevated on every device ISE fronts without any per-device change.

The group is empty at rest; membership exists only while a Britive checkout
is active. Checkin (checkin.py) removes it again.

For users that live in Active Directory rather than ISE's internal store, use
the Active Directory group-membership scripts instead; ISE evaluates AD groups
the same way.

Required environment variables:
  ISE_HOST, ISE_ERS_USER, ISE_ERS_PASSWORD   see ise_ers.py
  BRITIVE_USER_EMAIL     Requesting identity (Britive-injected), e.g. alice@example.com
  ISE_TARGET_GROUP       Identity group to join, e.g. NET-ADMIN-15

Optional:
  ISE_USERNAME           Override the ISE internal username (default: the local
                         part of BRITIVE_USER_EMAIL, i.e. "alice")
  ISE_ERS_PORT, ISE_VERIFY_TLS, ISE_CA_BUNDLE   see ise_ers.py

Stdout: one JSON line {"login","group","ise_host","groups"}; no credential is
        returned because the user keeps authenticating with their own password.
Stderr: progress.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ise_ers as ise  # noqa: E402

EMAIL = ise.env_required('BRITIVE_USER_EMAIL')
GROUP = ise.env_required('ISE_TARGET_GROUP')
USERNAME = os.environ.get('ISE_USERNAME') or EMAIL.split('@', 1)[0]


def main():
    ise.log(f'Checkout: add ISE internal user "{USERNAME}" to identity group "{GROUP}" on {ise.ISE_HOST}')

    user = ise.find_internal_user(USERNAME)
    if user is None:
        ise.log(f'ERROR: internal user "{USERNAME}" does not exist in ISE. '
                'This script elevates existing users; it does not create them.')
        sys.exit(1)

    group_id = ise.find_identity_group_id(GROUP)
    current = [g for g in (user.get('identityGroups') or '').split(',') if g]

    if group_id in current:
        ise.log(f'  "{USERNAME}" is already a member of "{GROUP}" (leftover from an earlier checkout); nothing to change.')
    else:
        ise.set_user_groups(user, current + [group_id])
        ise.log(f'  Added "{USERNAME}" to "{GROUP}".')

    # Verify
    after = ise.find_internal_user(USERNAME)
    groups_after = [g for g in (after.get('identityGroups') or '').split(',') if g]
    if group_id not in groups_after:
        ise.log(f'ERROR: verification failed — "{USERNAME}" is not in "{GROUP}" after the update.')
        sys.exit(1)

    ise.emit({
        'login': USERNAME,
        'group': GROUP,
        'ise_host': ise.ISE_HOST,
        'groups': groups_after,
        'note': 'Authenticate with your own ISE password; the group grants the elevated authorization.',
    })


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        ise.log(f'ERROR: {e}')
        sys.exit(1)
