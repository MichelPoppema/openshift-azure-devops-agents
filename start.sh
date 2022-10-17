#!/bin/bash
set -e

# Required environment variables:
# AZP_TOKEN: Personal Access Token
# AZP_URL: Azure DevOps organization or collection url
# Optional environment variables:
# AZP_WORK: Work directory of agent (default '_work')
# AZP_POOL: The pool the agent will belong to (default: 'Default') 
# AZP_AGENT_NAME: Name of the agent in the pool (default: valueOf uname -n)
# AZP_AGENTPACKAGE_URL: If set don't use the matching Azure Pipelines agent but this url to download the agent
# AZP_CAPABILITY_ENV_VARS: If set dont exclude only AZP_* variables but include only the named environment variables as system capabilities.

restart_with_clean_env() {
    if [ -z "$AZP_TOKEN" ]; then
      read -t 10 AZP_TOKEN
    else
      local TOKEN=$AZP_TOKEN
      unset AZP_TOKEN
      export AZP_URL AZP_POOL AZP_WORK AZP_AGENT_NAME AZP_AGENTPACKAGE_URL AZP_CAPABILITY_ENV_VARS
      exec $@ <<< $TOKEN
    fi      
}

cat_log() {
  cat /azp/agent/_diag/Agent_*-utc.log
}

cleanup() {
  local AZP_TOKEN=$1
  local AZP_URL=$2
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."
    
    # Workaround for preventing VS30063 message (only permissions on project level)
    [[ -e .agent ]] && sed -i 's@"serverUrl".*@"serverUrl": "'${AZP_URL}'",@' .agent

    ./config.sh remove --unattended \
      --auth PAT \
      --token $AZP_TOKEN
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$@${nocolor}"
}

capablities_from_env() {
    if [ ${AZP_CAPABILITY_ENV_VARS+_} ]
    then
        # Create assosiative array [<varname>]=<varname> from current environment
        declare -A env_vars="($(compgen -v | sed 's/\(.*\)/[\1]=\1/g'))"
        # Remove alle entries listed in AZP_CAPABILITY_ENV_VARS
        for v in $AZP_CAPABILITY_ENV_VARS; do unset env_vars[$v]; done
        # Add the remainder (comma-seperated)
        export VSO_AGENT_IGNORE=VSO_AGENT_IGNORE,$(echo ${env_vars[@]}|sed 's/ /,/g')
    else
        # AZP_CAPABILITY_ENV_VARS not set so only exclude our own environment variables
        export VSO_AGENT_IGNORE=VSO_AGENT_IGNORE,AZP_TOKEN_AZP_URL$(for v in AZP_WORK AZP_POOL AZP_AGENT_NAME AZP_AGENTPACKAGE_URL; do [[ -v $v ]] && echo ",$v"; done)
    fi
}

agent() {
  if [ -z "$AZP_URL" ]; then
    echo 1>&2 "error: missing AZP_URL environment variable"
    exit 1
  fi

  # Recycle so we dont leak AZP_TOKEN in 'ps eww' output
  restart_with_clean_env $0 ${FUNCNAME[0]} $@

  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi

  if [ -n "$AZP_WORK" ]; then
    mkdir -p "$AZP_WORK"
  fi

  # Cleanup kubeconfig files
  rm -rf /home/.kube

  rm -rf /azp/agent
  mkdir /azp/agent
  cd /azp/agent

  print_header "1. Determining matching Azure Pipelines agent..."

  if [ -z "$AZP_AGENTPACKAGE_URL" ]; then
    local AZP_AGENT_RESPONSE=$(curl -LsS \
      -u user:$AZP_TOKEN \
      -H 'Accept:application/json;api-version=3.0-preview' \
      "$AZP_URL/_apis/distributedtask/packages/agent?platform=linux-x64")

    if echo "$AZP_AGENT_RESPONSE" | jq . >/dev/null 2>&1; then
      AZP_AGENTPACKAGE_URL=$(echo "$AZP_AGENT_RESPONSE" \
        | jq -r '.value | map([.version.major,.version.minor,.version.patch,.downloadUrl]) | sort | .[length-1] | .[3]')
    fi
  fi
  if [ -z "$AZP_AGENTPACKAGE_URL" -o "$AZP_AGENTPACKAGE_URL" == "null" ]; then
    echo 1>&2 "error: could not determine a matching Azure Pipelines agent - check that account '$AZP_URL' is correct and the token is valid for that account"
    exit 1
  fi

  print_header "2. Downloading and installing Azure Pipelines agent..."

  curl -LsS $AZP_AGENTPACKAGE_URL | tar -xz & wait $!

  source ./env.sh

  trap "cleanup $AZP_TOKEN $AZP_URL"'; exit 130' INT
  trap "cleanup $AZP_TOKEN $AZP_URL"'; exit 143' TERM

  # set VSO_AGENT_IGNORE to prevent some environment variables to become system capabilities
  capablities_from_env

  # Enable next line to catch contents of logfile on error
  #trap "cat_log" ERR

  print_header "3. Configuring Azure Pipelines agent..."

  ./config.sh --unattended \
    --agent "${AZP_AGENT_NAME:-$(uname -n)}" \
    --url "$AZP_URL" \
    --auth PAT \
    --token $AZP_TOKEN \
    --pool "${AZP_POOL:-Default}" \
    --work "${AZP_WORK:-_work}" \
    --replace \
    --acceptTeeEula & wait $!

  print_header "4. Running Azure Pipelines agent..."

  trap "cleanup $AZP_TOKEN $AZP_URL" EXIT
  
  # Clean environment so we dont leak those to pipeline jobs
  unset AZP_TOKEN AZP_WORK AZP_POOL AZP_URL AZP_AGENT_NAME AZP_AGENTPACKAGE_URL AZP_CAPABILITY_ENV_VARS

  # `exec` the node runtime so it's aware of TERM and INT signals
  # AgentService.js understands how to handle agent self-update and restart
  exec ./externals/node/bin/node ./bin/AgentService.js interactive --once & wait $!

  # We expect the above process to exit when it runs once,
  # so we now run a cleanup process to remove this agent
  # from the pool from the trap EXIT
}

[[ $(type -t $1) != function ]] || $@
