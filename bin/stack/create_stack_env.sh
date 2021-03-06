#!/usr/bin/env bash
#
# Takes docker-compose yaml and extracts the possible configurations, 
# including the default values. This can be used to make sure the 
# configuration is always complete.

set -e

# shellcheck disable=SC1091
source lib/shell_utils.sh
# shellcheck disable=SC1091
source lib/network_utils.sh

# Creates the blank env file and sets some standard header text
create_config() {
  rm -f "${OUTPUT_ENV_FILE}"
  touch "${OUTPUT_ENV_FILE}"
  chmod +x "${OUTPUT_ENV_FILE}"
}

# Write a header block to the env file
add_header_to_env_file() {
  local temp_env_file
  temp_env_file="$(mktemp)"
  # shellcheck disable=SC2016
  {
    echo '# This file contains overrides to values used in the <stack name>.yml file'
    echo '# used by docker-compose.'
    echo '# For example, the .yml file may contain a line like:'
    echo '#   - STROOM_JDBC_DRIVER_PASSWORD=${STROOM_DB_PASSWORD:-stroomuser}'
    echo '# This means docker will pass the environment variable STROOM_JDBC_DRIVER_PASSWORD'
    echo '# to the relevant container. The value for this will be taken from'
    echo '# STROOM_DB_PASSWORD or if that is not set then it will use the default value'
    echo '# of stroompassword1. To override the value used set it in this'
    echo '# file like so:'
    echo '# STROOM_DB_PASSWORD=MyNewPassword123'
    echo 
    echo '# The following line can be uncommented and set if you want to specify the'
    echo '# hostname used for all communication between the various services. If left'
    echo '# commented out, the stack scripts will determine the IP address of the host'
    echo '# and use that.'
    echo 
    echo '#HOST_IP=<enter you hostname here>'
    echo
    cat "${OUTPUT_ENV_FILE}"
  } > "${temp_env_file}"
  mv "${temp_env_file}" "${OUTPUT_ENV_FILE}"
}

# If var_name is "STROOM_TAG", replacement_value is "v6.1.2" and a line in
# ${INPUT_YAML_FILE} looks like:
#   image: "${STROOM_REPO:-gchq/stroom}:${STROOM_TAG:-v6.0-LATEST}"
# then it becomes 
#   image: "${STROOM_REPO:-gchq/stroom}:${STROOM_TAG:-v6.1.2}"
# This changes the default value, whilst still allowing it to be overridden
# via the env file at deployment time.
replace_in_yaml() {
  local -r var_name="$1"
  local -r replacement_value="\${${var_name}:-$2}"
  local -r regex="\\$\{${var_name}(:-?[^}]*)?}"

  #echo "${regex}"

  if grep -E --silent "${regex}" "${INPUT_YAML_FILE}"; then
    echo -e "  Overriding the value of ${YELLOW}${var_name}${NC} to ${BLUE}${replacement_value}${NC}"
    sed -i'' -E "s|${regex}|${replacement_value}|g" "${INPUT_YAML_FILE}"
  fi
}

# Given the path to a file of environemnt variables of the form
# XXX_XXX="some value"
# replace strings in the docker compose yaml like this:
#   yamlProp: "${XXX_XXX:-a default value}"
# with this:
#   yamlProp: "${XXX_XXX:-some value}"
apply_overrides_to_yaml() {

  local -r override_file="$1"
  # force a sub-shell so the sourcing doesn't pollute our shell
  (
    # source the file so we can read the override values
    # shellcheck disable=SC1091,SC1090
    source "${override_file}"

    grep -oE "^[ \t]*[A-Z0-9_]+=.*" "${override_file}" | while read -r line; do
      # Extract the var name and value from the override file line
      local var_name="${line%%=*}"
      # remove leading whitespace characters
      var_name="${var_name#"${var_name%%[![:space:]]*}"}"

      # Check this override variable is not in the whitelist as if we are
      # overriding then having the env var in the env file will have no
      # effect.
      if element_in "${var_name}" "${env_vars_whitelist[@]}"; then
        die "${RED}ERROR${NC}: Variable ${YELLOW}${var_name}${NC} cannot be both white-listed and overridden"
      fi

      # We have sourced the container version file so use bash indirect expansion
      # ('!') to get the value of var_name
      local var_value="${!var_name}"
      #echo "var_name: [${var_name}], var_value: [${var_value}]"

      replace_in_yaml "${var_name}" "${var_value}"
    done
  )
}

is_variable_overridden() {
  local var_name="$1"

  if grep -oPq "^[ \t]*${var_name}(?==)" "${OVERRIDE_FILE}"; then
    return 0
  else
    return 1
  fi
}

add_env_vars() {
  local -r CONTAINER_VERSIONS_FILE="container_versions.env"
  # Associative array to hold whitelisted_var_name => use_count
  declare -A whitelisted_use_counters

  # Associative array to hold var_name => var_value
  declare -A output_env_vars

  # Read the volume whitelist into an array
  local env_vars_whitelist=()
  if [ -f "${WHITELIST_FILE}" ]; then
    while read -r env_var_name; do
      if [[ ! "${env_var_name}" =~ ^[[:space:]]*(#.*)?$ ]]; then
        env_vars_whitelist+=("${env_var_name}")
        #echo "[${env_var_name}]"
        # Initialise the couter at zero for each whitelisted env var name
        # so we can track if any are not used
        whitelisted_use_counters[${env_var_name}]=0
      fi
    done < "${WHITELIST_FILE}"

    local use_whitelist=true
    echo -e "${GREEN}Adding white-listed environment variables to ${BLUE}${OUTPUT_ENV_FILE}${NC}"
    touch "${OUTPUT_ENV_FILE}"
  else
    echo -e "${RED}Warn${NC}: Environment variable whitelist file ${BLUE}${WHITELIST_FILE}${NC} not found."
    echo -e "${GREEN}Adding ALL environment variables to ${BLUE}${OUTPUT_ENV_FILE}${NC}"
    local use_whitelist=false
  fi

  # Scan the yml file to extract the default value to build an env file
  # In the yaml there are lines like:
  # - STROOM_JDBC_DRIVER_URL=jdbc:mysql://${STROOM_DB_HOST:-$HOST_IP}:${STROOM_DB_PORT:-3307}/stroom
  # and from lines like those we want to extract/transform to
  # STROOM_DB_HOST="$HOST_IP"
  # STROOM_DB_PORT="3307"
  all_env_vars=$( \
    # Bit of a fudge to ignore the echo lines in stroom-all-dbs.yml
    grep -v "\s* echoXXXXX" "${INPUT_YAML_FILE}" |
      # ignore commented lines
      grep -v '^\s*#' |
      # Extracts the params
      grep -Po "(?<=\\$\\{).*?(?=\\})" |
      # Replaces ':-' with '='
      sed "s/:-/=/g" |
      uniq |
      sort )

  # associative array to hold var_name => count
  declare -A usage_counters

  local last_var_name=""
  local last_var_value=""

  # Loop over all env vars found in the yaml
  while read -r env_var_name_value; do
    local var_name="${env_var_name_value%%=*}"
    local var_value="${env_var_name_value#*=}"

    # this bit of code keeps a count of the times we have seen each env
    # var, so we can warn about ones seen multiple times but not whitelisted
    if [[ -z "${usage_counters[${var_name}]}" ]]; then
      usage_counters[${var_name}]=1
    else
      # increment the counter
      (( usage_counters["${var_name}"]=usage_counters["${var_name}"] + 1 ))
    fi
    #echo "${var_name}: ${usage_counters[${var_name}]}"

    # If this env var is a whitelisted one then increment its count
    if [[ -n "${whitelisted_use_counters[${var_name}]}" ]]; then
      (( whitelisted_use_counters["${var_name}"]=whitelisted_use_counters["${var_name}"] + 1 ))
      #echo "Incrementing count for ${var_name}, new count ${whitelisted_use_counters["${var_name}"]}"
    fi

    #echo "${last_var_name}: ${last_var_value}"
    if [ "${var_name}" == "${last_var_name}" ]; then
      # Seen it already
      if [ "${var_value}" != "${last_var_value}" ]; then
				die "${RED}  Error${NC}:" \
          "Environment variable ${YELLOW}${var_name}${NC} has multiple values," \
          "${BLUE}${last_var_value}${NC} and ${BLUE}${var_value}${NC}"
      fi
    else
      # Not seen this var before.
      # Now add the env var to the env file if we don't have a whitelist file
      # or it is white-listed
      if [ "${use_whitelist}" = "false" ] \
        || element_in "${var_name}" "${env_vars_whitelist[@]}"; then

        echo -e "  ${YELLOW}${var_name}${NC}=${BLUE}${var_value}${NC}"

        # Add the env var to our assoc. array
        output_env_vars["${var_name}"]="${var_value}"
      fi
    fi
    last_var_name="${var_name}"
    last_var_value="${var_value}"

    # You may have bits in the yaml like:
    # STROOM_JDBC_DRIVER_URL=jdbc:mysql://${STROOM_DB_HOST:-$HOST_IP}
    # and substitution of the default value doesn't work so we must white list it
    if [ "${use_whitelist}" = "true" ]; then
      if [[ "${var_value}" =~ \$[A-Z_0-9]+ ]] \
        && [[ -z "${whitelisted_use_counters[${var_name}]}" ]] \
        && ! is_variable_overridden "${var_name}"; then

				die "${RED}  Error${NC}: Environment variable ${YELLOW}${var_name}${NC}=\"${BLUE}${var_value}${NC}\" contains a substitution variable but isn't white-listed."
			fi
    fi
  done <<< "${all_env_vars}"

  # Now write our env var out to a file
  echo -e "${GREEN}Writing environment variables file ${BLUE}${OUTPUT_ENV_FILE}${NC}"
  for var_name in "${!output_env_vars[@]}"; do
    local var_value="${output_env_vars[${var_name}]}"
    # OUTPUT_ENV_FILE already exists at this point
    # They must be exported as they need to be available to child processes,
    # i.e. docker-compose.
    echo "export ${var_name}=\"${var_value}\"" >> "${OUTPUT_ENV_FILE}"
  done

  # Error if any whitelisted env var is not used anywhere in the yaml
  echo -e "${GREEN}Checking for unused white-listed variables.${NC}"
  for var_name in "${!whitelisted_use_counters[@]}"; do
    #echo "count for ${var_name} = ${whitelisted_use_counters["${var_name}"]}"
    if [ "${whitelisted_use_counters[$var_name]}" -eq 0 ]; then
      die "${RED}  Error${NC}: White-listed environment variable ${YELLOW}${var_name}${NC} is not used in the yaml."
    fi
  done

  # TODO not sure if we care about this or not
  # Output warnings if an env var is used more than once in the yaml but is
  # not whitelisted.
  #echo -e "${GREEN}Checking for environment variables used multiple times${NC}"
  #for var_name in "${!usage_counters[@]}"; do
    ##echo "count for ${var_name} = ${whitelisted_use_counters["${var_name}"]}"
    #if [ "${usage_counters[$var_name]}" -gt 1 ] \
      #&& [[ -z "${whitelisted_use_counters[${var_name}]}" ]] ; then

      #echo -e "${GREEN}  Info${NC}: Environment variable ${YELLOW}${var_name}${NC} is used multiple times in the yaml."
    #fi
  #done

  # The yaml file contains stuff like "${STROOM_TAG:-v6.0-LATEST}", 
  # i.e. development docker tags, so we need to replace them with fixed versions 
  # from CONTAINER_VERSIONS_FILE. 
  echo -e "${GREEN}Setting container versions in YAML file${NC}"
  apply_overrides_to_yaml "${CONTAINER_VERSIONS_FILE}"

  # If there is a override file then replace any matching env
  # vars found in the OUTPUT_ENV_FILE with the values from the override file.
  # This allows a stack to differ slightly from the defaults taken from the yml
  if [ -f "${OVERRIDE_FILE}" ]; then
    echo -e "${GREEN}Applying variable overrides to YAML file${NC}"
    apply_overrides_to_yaml "${OVERRIDE_FILE}"
  fi
}

create_versions_file() {

  # Produce a list of fully qualified docker image tags by sourcing the OUTPUT_ENV_FILE
  # that contains all the env vars and using their values to do variable substitution
  # against the image definitions obtained from the yml (INPUT_YAML_FILE)
  # Source the env file in a subshell to avoid poluting ours
  # shellcheck disable=SC1090
  ( 
    source "${OUTPUT_ENV_FILE}"

    # Find all image: lines in the yml and turn them into echo statements so we can
    # eval them so bash does its variable substitution. Bit hacky using eval.
    grep "image:" "${INPUT_YAML_FILE}" | 
      sed -e 's/\s*image:\s*/echo /g' | 
      while read -r line; do
        eval "${line}"
      done 
  ) | sort | uniq > "${VERSIONS_FILE}"

  echo -e "${GREEN}Using container versions:${NC}"

  while read -r line; do
    echo -e "  ${BLUE}${line}${NC}"
  done < "${VERSIONS_FILE}" 

  # TODO validate tags
  #if docker_tag_exists library/nginx 1.7.5; then
  #echo exist
  #else 
  #echo not exists
  #fi
}

main() {
  setup_echo_colours

  echo -e "${GREEN}Creating configuration${NC}"

  local -r BUILD_STACK_NAME=$1
  local -r VERSION=$2
  # shellcheck disable=SC2034
  local -r SERVICES=("${@:3}")
  local -r BUILD_DIRECTORY="build/${BUILD_STACK_NAME}"
  local -r STACK_DEFINITIONS_DIR="stack_definitions/${BUILD_STACK_NAME}"
  local -r WORKING_DIRECTORY="${BUILD_DIRECTORY}/${BUILD_STACK_NAME}-${VERSION}/config"
  mkdir -p "${WORKING_DIRECTORY}"
  local -r INPUT_YAML_FILE="${WORKING_DIRECTORY}/${BUILD_STACK_NAME}.yml"
  local -r OUTPUT_ENV_FILE="${WORKING_DIRECTORY}/${BUILD_STACK_NAME}.env"
  local -r OVERRIDE_FILE="${STACK_DEFINITIONS_DIR}/overrides.env"
  local -r WHITELIST_FILE="${STACK_DEFINITIONS_DIR}/env_vars_whitelist.txt"
  local -r VERSIONS_FILE="${WORKING_DIRECTORY}/../VERSIONS.txt"

  echo -e "${GREEN}Setting stack name in yaml file${NC}"
  replace_in_yaml "STACK_NAME" "${BUILD_STACK_NAME}"

  create_config
  add_env_vars

  # Sort and de-duplicate param list before we do anything else with the file
  sort -o "${OUTPUT_ENV_FILE}" -u "${OUTPUT_ENV_FILE}"
  add_header_to_env_file
  create_versions_file
}

main "$@"
