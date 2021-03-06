#!/usr/bin/env bash

############################################################################
# 
#  Copyright 2019 Crown Copyright
# 
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# 
############################################################################

# Re-usable network functions

source "${DIR:-.}"/lib/shell_utils.sh

determine_host_address() {
    if [ "$(uname)" == "Darwin" ]; then
        # Code required to find IP address is different in MacOS
        ip=$(ifconfig | grep "inet " | grep -Fv 127.0.0.1 | awk 'NR==1{print $2}')
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


wait_for_200_response() {
    if [[ $# -ne 1 ]]; then
        echo -e "${RED}Invalid arguments to wait_for_200_response(), expecting a URL to wait for${NC}"
        exit 1
    fi

    local -r url=$1
    local -r maxWaitSecs=120
    echo

    n=0
    # Keep retrying for maxWaitSecs
    until [ "$n" -ge "${maxWaitSecs}" ]
    do
        # OR with true to prevent the non-zero exit code from curl from stopping our script
        responseCode=$(curl -sL -w "%{http_code}\\n" "${url}" -o /dev/null || true)
        #echo "Response code: ${responseCode}"
        if [[ "${responseCode}" = "200" ]]; then
            break
        fi
        # print a simple unbounded progress bar, increasing every 2s
        mod=$(( n % 2 ))
        if [[ ${mod} -eq 0 ]]; then
            printf '.'
        fi

        n=$(( n + 1 ))
        # sleep for two secs
        sleep 1
    done
    printf "\n"

    if [[ $n -ge ${maxWaitSecs} ]]; then
        echo -e "${RED}Gave up wating for stroom to start up, check the logs (${BLUE}docker logs stroom${NC}${RED})${NC}"
    fi
}
