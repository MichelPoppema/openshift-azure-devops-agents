#!/bin/bash
set -e

# Required environment variables:
# AZP_TOKEN: Personal Access Token
# AZP_URL: Azure DevOps organization or collection url
# Optional environment variables:
# AZP_WORK: Work directory of agent (default '_work')
# AZP_POOL: The pool the agent will belong to (default: 'Default') 
# AZP_AGENT_NAME: Name of the agent in the pool (default: valueOf uname -n)
# AZP_AGENT_PACKAGE_LATEST_URL: If set don't use the matching Azure Pipelines agent but this url to download the agent
# AZP_CAPABILITY_ENV_VARS: If set dont exclude only AZP_* variables but include only the named environment variables as system capabilities.


restart_with_clean_env() {
    if [ -z "$AZP_TOKEN" ]; then
      read -t 10 AZP_TOKEN
    else
      local TOKEN=$AZP_TOKEN
      unset AZP_TOKEN
      export AZP_URL AZP_POOL AZP_WORK AZP_AGENT_NAME AZP_AGENT_PACKAGE_LATEST_URL AZP_CAPABILITY_ENV_VARS TARGETARCH
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

    # Disable agent to prevent new jobs to start
    local AZP_POOL_ID=$(jq '.poolId//""' .agent) || true
    local AZP_AGENT_ID=$(jq '.agentId//""' .agent) || true
    if [[ ! -z "$AZP_POOL_ID" && ! -z "$AZP_AGENT_ID" ]]; then
      local AZP_DISABLE_RESPONSE=$(curl -LsS -X PATCH -u :$AZP_TOKEN -H 'Content-Type: application/json' \
        -d "{\"id\":$AZP_AGENT_ID,\"enabled\":false}" \
        $AZP_URL/_apis/distributedtask/pools/$AZP_POOL_ID/agents/$AZP_AGENT_ID?api-version=5.0 || true)
    fi
    
    # Workaround for preventing VS30063 message (only permissions on project level)
    [[ -e .agent ]] && sed -i 's@"serverUrl".*@"serverUrl": "'${AZP_URL}'",@' .agent

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      ./config.sh remove --unattended --auth PAT --token $AZP_TOKEN && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
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
        local AZP_OPTIONALS="AZP_WORK AZP_POOL AZP_AGENT_NAME AZP_AGENT_PACKAGE_LATEST_URL"
        export VSO_AGENT_IGNORE=VSO_AGENT_IGNORE,AZP_TOKEN,AZP_URL$(for v in $AZP_OPTIONALS; do [[ -v $v ]] && echo ",$v"; done)
    fi
}

agent() {
  if [ -z "$AZP_URL" ]; then
    echo 1>&2 "error: missing AZP_URL environment variable"
    exit 1
  fi

  ### Recycle so we dont leak AZP_TOKEN in 'ps eww' output
  restart_with_clean_env $0 ${FUNCNAME[0]} $@

  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi

  if [ -n "$AZP_WORK" ]; then
    mkdir -p "$AZP_WORK"
  fi

### Cleanup kubeconfig files
  rm -rf /home/.kube

  rm -rf /azp/agent
  mkdir /azp/agent
  cd /azp/agent

  # Let the agent ignore the token env variable
  export VSO_AGENT_IGNORE=AZP_TOKEN
  
  ### Hide even more
  capablities_from_env

  print_header "1. Determining matching Azure Pipelines agent..."

  if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" ]; then
    local AZP_AGENT_PACKAGES=$(curl -LsS \
        -u user:$AZP_TOKEN \
        -H 'Accept:application/json;' \
        "$AZP_URL/_apis/distributedtask/packages/agent?platform=$TARGETARCH&top=1")

    AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')

    if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" -o "$AZP_AGENT_PACKAGE_LATEST_URL" == "null" ]; then
      echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
      echo 1>&2 "check that account '$AZP_URL' is correct and the token is valid for that account"
      exit 1
    fi
  fi

  print_header "2. Downloading and installing Azure Pipelines agent..."

  curl -LsS $AZP_AGENT_PACKAGE_LATEST_URL | tar -xz & wait $!

  source ./env.sh

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

  trap "cleanup $AZP_TOKEN $AZP_URL"'; exit 0' EXIT
  trap "cleanup $AZP_TOKEN $AZP_URL"'; exit 130' INT
  trap "cleanup $AZP_TOKEN $AZP_URL"'; exit 143' TERM

  chmod +x ./run-docker.sh

  ### Clean environment
  unset AZP_TOKEN AZP_WORK AZP_POOL AZP_URL AZP_AGENT_NAME AZP_AGENT_PACKAGE_LATEST_URL AZP_CAPABILITY_ENV_VARS

  # To be aware of TERM and INT signals call run.sh
  # Running it with the --once flag at the end will shut down the agent after the build is executed
  ./run-docker.sh "$@" & wait $!
}

[[ $(type -t $1) != function ]] || $@
