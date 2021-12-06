#!/bin/bash

function display_help() {
  echo "Usage: python.bash [OPTION]..."
  echo "Python clone repository and/or create new venv"
  echo ""
  echo "  -h, --help                    display this help and exit"
  exit
}

while getopts :h option; do
  case ${option} in
    h) display_help ;;
  esac
done
