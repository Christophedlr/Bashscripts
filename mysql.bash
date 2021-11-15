#!/bin/bash

function display_help() {
    echo "Usage: mysql.bash [OPTION]..."
    echo "Manage MySQL or MariaDB database"
    echo ""
    echo "  -h, --help              display this help and exit"
}

while getopts :h option; do
    if [[ "$option" = "-" ]]; then
        case $OPTARG in
            help) option=h ;;
        esac
    fi
    case ${option} in
    h) display_help ;;
    esac
done
