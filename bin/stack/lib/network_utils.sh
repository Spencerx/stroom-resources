#!/usr/bin/env bash
#
# Re-usable network functions

setup_echo_colours() {
    # Exit the script on any error
    set -e

    #Shell Colour constants for use in 'echo -e'
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[1;34m'
    LGREY='\e[37m'
    DGREY='\e[90m'
    NC='\033[0m' # No Color
}

determine_host_address() {
    if [ "$(uname)" == "Darwin" ]; then
        # Code required to find IP address is different in MacOS
        ip=$(ifconfig | grep "inet " | grep -Fv 127.0.0.1 | awk '{print $2}')
    else
        ip=$(ip route get 1 |awk 'match($0,"src [0-9\\.]+") {print substr($0,RSTART+4,RLENGTH-4)}')
    fi

    if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo
        echo -e "${RED}ERROR${NC} IP address [${GREEN}${ip}${NC}] is not valid, try setting '${BLUE}STROOM_RESOURCES_ADVERTISED_HOST=x.x.x.x${NC}' in ${BLUE}local.env${NC}" >&2
        exit 1
    fi

    echo "$ip"
}
