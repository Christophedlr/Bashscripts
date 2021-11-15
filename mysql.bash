#!/bin/bash

USER="root"
PASSWORD=""

function display_help() {
    echo "Usage: mysql.bash [OPTION]..."
    echo "Manage MySQL or MariaDB database"
    echo ""
    echo "  -h, --help                  display this help and exit"
    echo "  -u, --user=user             indicate a user MySQL (by default is root user)"
    echo "  -p, --password=password     indicate a user MySQL password"
    exit
}

while getopts :hp:u: option; do
    if [[ "$option" = "-" ]]; then
        case $OPTARG in
            help) option=h ;;
            password) option=p ;;
            user) option=u ;;
        esac
    fi
    case ${option} in
    h) display_help ;;
    p) PASSWORD=$OPTARG ;;
    u) USER=$OPTARG ;;
    esac
done

if [[ -z ${PASSWORD} ]]; then
    read -p "Enter a ${USER} password: " -s PASSWORD
    echo ""
fi
