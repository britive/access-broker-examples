#!/bin/bash

# Test script to list of all users and groups on an Ubuntu system
# This script will list all system users, users in the 'sudo' group, and explicit sudoers

echo "All system users:"
cut -d: -f1 /etc/passwd

echo -e "\nUsers in 'sudo' group:"
getent group sudo | cut -d: -f4 | tr ',' '\n'

echo -e "\nExplicit sudoers (sudoers/sudoers.d):"
sudo grep -r 'ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null