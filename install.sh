#!/bin/bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CHECK_MARK="\033[0;32m\xE2\x9C\x94\033[0m"


echo -n "Updating..."
apt update


echo -n "Installing direnv to manage env files..."
{
    DEBIAN_FRONTEND=noninteractive apt -y install direnv
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed direnv."


echo -n "Installing fail2ban..."
{
    DEBIAN_FRONTEND=noninteractive apt -y install fail2ban
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed fail2ban."


echo -n "Installing and configuring ferm..."
{
    DEBIAN_FRONTEND=noninteractive apt -y install ferm

    echo "Backing up original ferm config..."
    mv /etc/ferm/ferm.conf /etc/ferm/ferm.conf.bak
    mv /etc/ferm/ferm.d /etc/ferm/ferm.d.bak

    echo "Deploying new ferm config..."
    cp -r "${SCRIPT_DIR}/.ferm/"* /etc/ferm/

    if ip link show | grep -q "eth0"; then
        for rule in /etc/ferm/ferm.d/*; do
            sed -i 's/venet0/eth0/g' "$rule"
        done
    fi

    echo "Test ferm config:"
    ferm --noexec /etc/ferm/ferm.conf

    echo "Enabling ferm config:"
    ferm /etc/ferm/ferm.conf
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed ferm."
