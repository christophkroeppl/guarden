#!/bin/bash

CHECK_MARK="\033[0;32m\xE2\x9C\x94\033[0m"

echo -n "Installing and configuring ferm..."
{
    apt update
    DEBIAN_FRONTEND=noninteractive apt-get -y install ferm
    rm -r /etc/ferm/*
    cp .ferm/* /etc/ferm/

    if ifconfig | grep "eth0"; then
        sed -i "s/venet0/eth0/g" /etc/ferm/ferm.d/30-in.docker.public-ports.ferm
        sed -i "s/venet0/eth0/g" /etc/ferm/ferm.d/99-docker.ferm
    fi

} >> install.log 2>&1

echo -e "\\r${CHECK_MARK} Succesfully installed ferm. Rebooting now..."
reboot