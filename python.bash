#!/bin/bash

DEFAULT="y"
GIT_REPOS=""
LOCATION=""
CLONE=""

function display_help() {
  echo "Usage: python.bash [OPTION]..."
  echo "Python clone repository and/or create new venv"
  echo ""
  echo "  -h                            display this help and exit"
  exit
}

function check_python() {
  if [[ -z `which python3` ]]; then
    echo "Python 3 not found"
    exit
  fi
}

while getopts :h option; do
  case ${option} in
    h) display_help ;;
  esac
done

read -p "Clone repository ? [Y/n] " -n 1 CLONE
echo ""

if [[ ${CLONE} = "" ]]; then
  CLONE=${DEFAULT}
fi

if [[ ${CLONE} = "y" ]]; then
  read -p "Repository: " GIT_REPOS
  read -p "Destination directory: " LOCATION
  echo ""

  echo "Clone repository ${GIT_REPOS}"
  git clone ${GIT_REPOS} ${LOCATION}
  echo ""

  echo "Create the Virtual Environment"

  check_python

  python3 -m venv "${LOCATION}/venv"
  echo ""
  echo "Install requirements"
  "${LOCATION}"/venv/bin/pip install -r "${LOCATION}"/requirements.txt

  echo ""
  echo "Your project has been cloned and configured"
fi
