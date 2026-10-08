#!/usr/bin/env python3
"""
Cisco ISE — Identity Group Checkin — Britive Access Broker

Removes the ISE internal user from the identity group added by checkout.py.
Idempotent: if the user is already out of the group, exits 0.

Note: TACACS+/RADIUS authorize at login. Removing the group stops NEW sessions
from being elevated; an already-open session keeps its privilege until it
ends. Front the devices with Britive Bridge so the session closes at expiry.

Required environment variables:
  ISE_HOST, ISE_ERS_USER, ISE_ERS_PASSWORD   see ise_ers.py
  BRITIVE_USER_EMAIL
  ISE_TARGET_GROUP

Optional:
  ISE_USERNAME, ISE_ERS_PORT, ISE_VERIFY_TLS, ISE_CA_BUNDLE

Stdout: nothing. Stderr: progress.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ise_ers as ise  # noqa: E402

EMAIL = ise.env_required('BRITIVE_USER_EMAIL')
GROUP = ise.env_required('ISE_TARGET_GROUP')
USERNAME = os.environ.get('ISE_USERNAME') or EMAIL.split('@', 1)[0]


def main():
    ise.log(f'Checkin: remove ISE internal user "{USERNAME}" from identity group "{GROUP}" on {ise.ISE_HOST}')

    user = ise.find_internal_user(USERNAME)
    if user is None:
        ise.log(f'  internal user "{USERNAME}" no longer exists in ISE; nothing to remove.')
        return

    group_id = ise.find_identity_group_id(GROUP)
    current = [g for g in (user.get('identityGroups') or '').split(',') if g]

    if group_id not in current:
        ise.log(f'  "{USERNAME}" is not a member of "{GROUP}"; nothing to change.')
        return

    ise.set_user_groups(user, [g for g in current if g != group_id])

    after = ise.find_internal_user(USERNAME)
    groups_after = [g for g in (after.get('identityGroups') or '').split(',') if g]
    if group_id in groups_after:
        ise.log(f'ERROR: verification failed — "{USERNAME}" is still in "{GROUP}". '
                'Remove manually in ISE: Administration > Identity Management > Identities.')
        sys.exit(1)
    ise.log(f'  Removed "{USERNAME}" from "{GROUP}".')


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        ise.log(f'ERROR: {e}')
        sys.exit(1)
