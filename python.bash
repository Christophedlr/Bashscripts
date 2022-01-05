#!/bin/bash

DEFAULT="y"
GIT_REPOS=""
LOCATION=""
CLONE=""
NEW=""
PROJECT=""
PACKAGE=""
INSTALL=""
VERSION=""

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

function create_venv() {
  if [[ -z `which pv` ]]; then
    python3 -m venv "${LOCATION}/venv"
  else
    python3 -m venv "${LOCATION}/venv" | pv -t
  fi
}

function install_requirements() {
  echo "Install requirements"
  "${LOCATION}"/venv/bin/pip install -r "${LOCATION}"/requirements.txt
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
  create_venv
  echo ""
  install_requirements

  echo ""
  echo "Your project has been cloned and configured"
else
  read -p "Create new project ? [Y/n] " -n 1 NEW
  echo ""

  if [[ ${NEW} = "" ]]; then
    NEW=${DEFAULT}
  fi

  if [[ ${NEW} = "y" ]]; then
    check_python
    read -p "Name of project: " PROJECT

    if [[ ${PROJECT} = "" ]]; then
      echo "Project name is required"
      exit
    fi

    read -p "Location of project: " LOCATION
    mkdir -p "${LOCATION}"/"${PROJECT}"
    LOCATION="${LOCATION}"/"${PROJECT}"
    create_venv

    read -p "Install packages ? [Y/n] " -n 1 INSTALL
    echo ""

    if [[ ${INSTALL} = "" ]]; then
    INSTALL=${DEFAULT}
    fi

    if [[ ${INSTALL} = "y" ]]; then
      while true; do
          read -p "Package name: " PACKAGE

          if [[ -z "${PACKAGE}" ]]; then
            break
          fi

          read -p "Version: " VERSION

          echo "Adding package in requirements"
          echo "${PACKAGE}==${VERSION}" >> "${LOCATION}"/requirements.txt
          echo ""
      done

      install_requirements
    fi

    echo "Your project has been created"
  fi
fi
