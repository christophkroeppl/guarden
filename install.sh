#!/bin/bash

CHECK_MARK="\033[0;32m\xE2\x9C\x94\033[0m"


echo -n "Updating..."
apt update


echo -n "Installing and configuring fail2ban..."
{
    DEBIAN_FRONTEND=noninteractive apt-get -y install fail2ban
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed fail2ban."


echo -n "Installing and configuring ferm..."
{
    DEBIAN_FRONTEND=noninteractive apt-get -y install ferm

    echo "Backing up original ferm config..."
    mv /etc/ferm/ferm.conf /etc/ferm/ferm.conf.bak
    mv /etc/ferm/ferm.d /etc/ferm/ferm.d.bak

    echo "Deploying new ferm config..."
    cp -r .ferm/* /etc/ferm/

    if ip link show | grep "eth0"; then
        # TODO: run sed on all files in ferm.d
        sed -i "s/venet0/eth0/g" /etc/ferm/ferm.d/30-in.docker.public-ports.ferm
        sed -i "s/venet0/eth0/g" /etc/ferm/ferm.d/99-docker.ferm
    fi

    echo "Test ferm config:"
    ferm --noexec /etc/ferm/ferm.conf

    echo "Enabling ferm config:"
    ferm /etc/ferm/ferm.conf
} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed ferm."
