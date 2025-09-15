#!/bin/bash
# manage_as400_user.sh
# Britive-compatible IBM i user access automation
# Uses IBM ACS 'system' if available, otherwise falls back to SSH

set -e

AS400_HOST="${AS400_HOST:?Missing AS400_HOST}"
AS400_ADMIN_USER="${AS400_ADMIN_USER:?Missing AS400_ADMIN_USER}"
AS400_ACTION="${AS400_ACTION:?Missing AS400_ACTION}"
AS400_TARGET_USER="${AS400_TARGET_USER:?Missing AS400_TARGET_USER}"
AS400_PASSWORD="${AS400_PASSWORD}"
AS400_DESCRIPTION="${AS400_DESCRIPTION:-Temporary User}"
AS400_GROUP="${AS400_GROUP:-*NONE}"

has_acs() {
    command -v system >/dev/null 2>&1
}

invoke_acs() {
    local cmd="$1"
    echo "Running via ACS: $cmd"
    system "${AS400_HOST};user=${AS400_ADMIN_USER};command=${cmd}"
}

invoke_ssh() {
    local cmd="$1"
    echo "Running via SSH: $cmd"
    ssh "${AS400_ADMIN_USER}@${AS400_HOST}" "$cmd"
}

if has_acs; then
    runner="invoke_acs"
else
    runner="invoke_ssh"
fi

case "$(echo "$AS400_ACTION" | tr '[:upper:]' '[:lower:]')" in
    checkout)
        if [ -z "$AS400_PASSWORD" ]; then
            echo "AS400_PASSWORD is required for create."
            exit 1
        fi
        $runner "CRTUSRPRF USRPRF($AS400_TARGET_USER) PASSWORD('$AS400_PASSWORD') USRCLS(*USER) TEXT('$AS400_DESCRIPTION')"
        if [ "$AS400_GROUP" != "*NONE" ]; then
            $runner "CHGUSRPRF USRPRF($AS400_TARGET_USER) GRPPRF($AS400_GROUP)"
        fi
        echo "✅ Created user $AS400_TARGET_USER in group $AS400_GROUP"
        ;;
    disable)
        $runner "CHGUSRPRF USRPRF($AS400_TARGET_USER) STATUS(*DISABLED)"
        echo "🚫 Disabled user $AS400_TARGET_USER"
        ;;
    checkin) # Choose between and this and above command for Delete or Disable
        $runner "DLTUSRPRF USRPRF($AS400_TARGET_USER) OWNOBJOPT(*DLT)"
        echo "🗑 Deleted user $AS400_TARGET_USER"
        ;;
    *)
        echo "Invalid AS400_ACTION. Use checkout or checkin."
        exit 1
        ;;
esac
