#!/bin/bash

DEFAULT="y"
USER="root"
PASSWORD=""

function check_password() {
    if [[ -z ${PASSWORD} ]]; then
        read -p "Enter a ${USER} password: " -s PASSWORD
        echo ""
    fi
}

function display_help() {
    echo "Usage: mysql.bash [OPTION]..."
    echo "Manage MySQL or MariaDB database"
    echo ""
    echo "  -h, --help                  display this help and exit"
    echo "  -u, --user=user             indicate a user MySQL (by default is root user)"
    echo "  -p, --password=password     indicate a user MySQL password"
    echo "  --cdb                       Create a database"
    echo "  --ddb                       Delete a database"
    echo "  --sdb=dbname                Save a database"
    echo "  --rdb=dbname                Restore a database"
    exit
}


function create_database() {
    SQL=""
    ERROR=""

    if [[ $# -eq 3 ]]; then
        SQL="CREATE DATABASE IF NOT EXISTS \`$1\`;"
        echo ""
        echo "Create database $1"

        if [[ $3 = "y" ]]; then
            SQL="${SQL} GRANT ALL PRIVILEGES ON $1.* TO '$2'@localhost;"
            echo "Grant database privileges"
        fi

        SQL="${SQL} FLUSH PRIVILEGES;"
        mysql -u root --user=${USER} --password=${PASSWORD} -e "$SQL"

        if [[ $? -eq 0 ]]; then
            echo "Database ${NAME} has been created."
        fi

        history -c
    fi
}

function delete_database() {
    SQL=""
    ERROR=""

    if [[ $# -eq 3 ]]; then
        SQL="DROP DATABASE IF EXISTS \`$1\`;"
        echo ""
        echo "Delete database $1"

        if [[ $3 = "y" ]]; then
            SQL="${SQL} REVOKE ALL PRIVILEGES ON $1.* TO '$2'@localhost;"
            echo "Revoke database privileges"
        fi

        SQL="${SQL} FLUSH PRIVILEGES;"
        mysql -u root --user=${USER} --password=${PASSWORD} -e "$SQL"

        if [[ $? -eq 0 ]]; then
            echo "Database ${NAME} has been deleted."
        fi

        echo ""

        history -c
    fi
}

function create_database_query() {
    NAME=""
    GRANT=""
    USERNAME="none"

    check_password

    read -p "Name of database: " NAME
    read -p "Grant all privileges for an user ? [Y/n]" -n 1 GRANT

    if [[ ${GRANT} = "" ]]; then
        GRANT=${DEFAULT}
    fi

    if [[ ${GRANT} = "y" ]]; then
        read -p "Name of existing user: " USERNAME
    fi

    create_database ${NAME} ${USERNAME} ${GRANT}
}

function delete_database_query() {
    NAME=""
    GRANT=""
    USERNAME=""

    check_password

    read -p "Name of database: " NAME
    read -p "Revoke all privileges for an user of database ? [Y/n]" -n 1 GRANT

    if [[ ${GRANT} = "" ]]; then
        GRANT=${DEFAULT}
    fi

    if [[ ${GRANT} = "y" ]]; then
        read -p "Name of existing user: " USERNAME
    fi

    delete_database ${NAME} ${USERNAME} ${GRANT}
}

function save_database() {
    echo "Saving database $1"
    if [[ -z `which pv` ]]; then
        mysqldump -u ${USER} --password=${PASSWORD} --default-character-set=utf8 -i -B -a $1 > $1.sql
    else
        mysqldump -u ${USER} --password=${PASSWORD} --default-character-set=utf8 -i -B -a $1 |pv > $1.sql
    fi

    tar -cf $1.tar.gz $1.sql
    rm -f $1.sql
    history -c
}

function restore_database() {
    echo "Restore database $1"
    tar -xf $1.tar.gz

    if [[ -z `which pv` ]]; then
        mysql -u ${USER} --password=${PASSWORD} < $1.sql
    else
        pv $1.sql | mysql -u ${USER} --password=${PASSWORD}
    fi

    rm -r $1.sql
    history -c
    echo "Database restored!"
}

while getopts :-:hp:u: option; do
    case ${option} in
    -)
        VALUE=${OPTARG#*=}
        ARG=${OPTARG%=${VALUE}}

        case ${OPTARG} in
            help)
                display_help
            ;;
            user=*)
                USER=${VALUE}
            ;;
            password=*)
                PASSWORD=${VALUE}
            ;;
            cdb)
                create_database_query
            ;;
            ddb)
                delete_database_query
            ;;
            sdb=*)
                save_database ${VALUE}
            ;;
            rdb=*)
                restore_database ${VALUE}
            ;;
        esac
    ;;
    h) display_help ;;
    p) PASSWORD=$OPTARG ;;
    u) USER=$OPTARG ;;
    esac
done
