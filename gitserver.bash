#!/bin/bash

DEFAULT="y"
REPOSITORY=""
LOCATION_GIT_REPOS=""
APACHE2_GIT_CONF=""
LOCATION_GITCONF="/etc/apache2/conf-available"
DEFAULT_LOCATION_GIT_REPOS="/var/git"

function display_help() {
    echo "Usage: gitserver.bash [OPTION]..."
    echo "Manage Git server Apache configuration"
    echo ""
    echo "  -h, --help                  display this help and exit"
    exit
}

function questions() {
    read -p "Name of repository: " REPOSITORY
    read -p "Location of git root repositories [${DEFAULT_LOCATION_GIT_REPOS}/${REPOSITORY}.git]: " LOCATION_GIT_REPOS

    DEFAULT_APACHE2_GIT_CONF="git-${REPOSITORY}.conf"

    if [[ ${LOCATION_GIT_REPOS} = "" ]]; then
        LOCATION_GIT_REPOS="${DEFAULT_LOCATION_GIT_REPOS}/${REPOSITORY}.git"
    fi

    read -p "Name of apache2 git configuration file [${DEFAULT_APACHE2_GIT_CONF}]: " APACHE2_GIT_CONF

    if [[ ${APACHE2_GIT_CONF} = "" ]]; then
        APACHE2_GIT_CONF="${DEFAULT_APACHE2_GIT_CONF}"
    fi

    summary
}

function summary() {
    echo ""
    echo "Summary"
    echo "-------"
    echo ""
    echo "Repository name: ${REPOSITORY}"
    echo "Git root location: ${LOCATION_GIT_REPOS}"
    echo "Apache2 git conf: ${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
    read -p "That is OK ? [Y/n] " -n 1 RESPONSE

    if [[ ${RESPONSE} = "" ]]; then
        RESPONSE=${DEFAULT}
    elif [[ ${RESPONSE^^} = "N" ]]; then
        echo ""
        questions
    fi
}

while getopts :-:h option; do
    case ${option} in
    -)
        VALUE=${OPTARG#*=}
        ARG=${OPTARG%=${VALUE}}

        case ${OPTARG} in
            help)
                display_help
            ;;
        esac
    ;;
    h) display_help ;;
    esac
done

questions

echo "Creating apache2 configuration"
echo "SetEnv GIT_PROJECT_ROOT ${LOCATION_GIT_REPOS}" > "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "SetEnv GIT_HTTP_EXPORT_ALL" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "ScriptAlias /git/${REPOSITORY}.git /usr/lib/git-core/git-http-backend/" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "<LocationMatch /git/${REPOSITORY}.git>" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "    AuthType Basic" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "    AuthName \"Git ${REPOSITORY} repository\"" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "    AuthUserFile ${LOCATION_GIT_REPOS}/.htpasswd" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "    Require expr !(%{QUERY_STRING} -strmatch '*service=git-receive-pack*' || %{REQUEST_URI} =~ m#/git-receive-pack\$#)" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "    Require valid-user" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"
echo "</LocationMatch>" >> "${LOCATION_GITCONF}/${APACHE2_GIT_CONF}"

echo "Creating git repository"
git init --shared --bare ${LOCATION_GIT_REPOS}

echo "Creating user"
read -p "Username: " USERNAME
htpasswd -c ${LOCATION_GIT_REPOS}/.htpasswd ${USERNAME}
chown -R www-data:www-data ${LOCATION_GIT_REPOS}

echo "Enabling Apache2 configuration"
a2enconf ${APACHE2_GIT_CONF}
systemctl restart apache2

echo "Git ${REPOSITORY} repository created"
