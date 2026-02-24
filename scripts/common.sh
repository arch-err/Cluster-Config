#!/usr/bin/env bash
# Common functions for cluster scripts

# Exit with error message
die() {
    echo -e "\033[0;31mError:\033[0m $*" >&2
    exit 1
}

# Check if command exists
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# Check if running as root or with sudo
require_sudo() {
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        die "This script requires sudo access"
    fi
}
