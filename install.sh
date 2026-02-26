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

    echo "Backing up original fail2ban config..."
    if [ -f /etc/fail2ban/jail.local ]; then
        mv /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak
    fi
    if [ -f /etc/fail2ban/jail.conf ]; then
        mv /etc/fail2ban/jail.conf /etc/fail2ban/jail.conf.bak
    fi
    if [ -d /etc/fail2ban/jail.d ]; then
        mv /etc/fail2ban/jail.d /etc/fail2ban/jail.d.bak
    fi

    echo "Deploying fail2ban config..."
    cp -r "${SCRIPT_DIR}/.fail2ban/"* /etc/fail2ban/

    echo "Restarting fail2ban..."
    systemctl restart fail2ban

    echo "Checking fail2ban status..."
    fail2ban-client status
    fail2ban-client status sshd
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed fail2ban."


echo -n "Installing and configuring ferm..."
{
    DEBIAN_FRONTEND=noninteractive apt -y install ferm

    echo "Backing up original ferm config..."
    mv /etc/ferm/ferm.conf /etc/ferm/ferm.conf.bak
    mv /etc/ferm/ferm.d /etc/ferm/ferm.d.bak

    echo "Deploying new ferm config..."
    cp "${SCRIPT_DIR}/.ferm/ferm.conf" /etc/ferm/
    cp -r "${SCRIPT_DIR}/.ferm/ferm.d" /etc/ferm/

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

echo -n "Configuring systemd auto-start for root Docker Compose stack..."
{
    SERVICE_NAME="srv-compose.service"
    SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
    TEMP_SERVICE="$(mktemp)"

    sed "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" "${SCRIPT_DIR}/.systemd/${SERVICE_NAME}" > "${TEMP_SERVICE}"

    if [ ! -f "${SERVICE_PATH}" ] || ! cmp -s "${TEMP_SERVICE}" "${SERVICE_PATH}"; then
        install -m 0644 "${TEMP_SERVICE}" "${SERVICE_PATH}"
        systemctl daemon-reload
    fi

    rm -f "${TEMP_SERVICE}"
    systemctl enable --now "${SERVICE_NAME}"
} >> install.log 2>&1

echo -e "\r${CHECK_MARK} Successfully configured systemd auto-start for the root compose stack."
