#!/usr/bin/env bash

set -ueo pipefail

usage() {
cat << EOF
Push Helm Chart to Nexus repository

This plugin provides ability to push a Helm Chart directory or package to a
remote Nexus Helm repository.

Usage:
  helm nexus-push [repo] login [flags]        Setup login information for repo
  helm nexus-push [repo] logout [flags]       Remove login information for repo
  helm nexus-push [repo] [CHART] [flags]      Pushes chart to repo

Flags:
  -u, --username string                 Username for authenticated repo (assumes anonymous access if unspecified)
  -p, --password string                 Password for authenticated repo (prompts if unspecified and -u specified)
EOF
}

function parse_yaml {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|,$s\]$s\$|]|" \
        -e ":1;s|^\($s\)\($w\)$s:$s\[$s\(.*\)$s,$s\(.*\)$s\]|\1\2: [\3]\n\1  - \4|;t1" \
        -e "s|^\($s\)\($w\)$s:$s\[$s\(.*\)$s\]|\1\2:\n\1  - \3|;p" $1 | \
   sed -ne "s|,$s}$s\$|}|" \
        -e ":1;s|^\($s\)-$s{$s\(.*\)$s,$s\($w\)$s:$s\(.*\)$s}|\1- {\2}\n\1  \3: \4|;t1" \
        -e    "s|^\($s\)-$s{$s\(.*\)$s}|\1-\n\1  \2|;p" | \
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)-$s[\"']\(.*\)[\"']$s\$|\1$fs$fs\2|p" \
        -e "s|^\($s\)-$s\(.*\)$s\$|\1$fs$fs\2|p" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" | \
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]; idx[i]=0}}
      if(length($2)== 0){  vname[indent]= ++idx[indent] };
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) { vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, vname[indent], $3);
      }
   }'
}

NEXUS_USERNAME=
NEXUS_PASSWORD=

declare -a POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]
do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -u|--username)
            if [[ -n "${2:-}" ]]; then
                shift
                NEXUS_USERNAME=$1
            fi
            ;;
        -p|--password)
            if [[ -n "${2:-}" ]]; then
                shift
                NEXUS_PASSWORD=$1
            fi
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            ;;
   esac
   shift
done
[[ ${#POSITIONAL_ARGS[@]} -ne 0 ]] && set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [[ $# -lt 2 ]]; then
  echo "Missing arguments!"
  echo "---"
  usage
  exit 1
fi

indent() { sed 's/^/  /'; }

declare REPO=$1
declare REPO_URL="$(helm repo list | grep "^$REPO" | awk '{print $2}')/"
declare REPO_AUTH_FILE="$(helm home)/repository/auth.$REPO"

declare REPOSITORIES_FILE="$(helm home)/repository/repositories.yaml"

if [[ -z "${REPO_URL}" ]]; then
    echo "Invalid repo specified!  Must specify one of these repos..."
    helm repo list
    echo "---"
    usage
    exit 1
fi

declare CMD
declare AUTH
declare CHART

case "$2" in
    login)
        if [[ -z "$NEXUS_USERNAME" ]]; then
            read -p "Username: " NEXUS_USERNAME
        fi
        if [[ -z "$NEXUS_PASSWORD" ]]; then
            read -s -p "Password: " NEXUS_PASSWORD
            echo
        fi
        echo "$NEXUS_USERNAME:$NEXUS_PASSWORD" > "$REPO_AUTH_FILE"
        ;;
    logout)
        rm -f "$REPO_AUTH_FILE"
        ;;
    *)
        CMD=push
        CHART=$2

        if [[ -z "$NEXUS_USERNAME" ]] || [[ -z "$NEXUS_PASSWORD" ]]; then
            if [[ -f "$REPO_AUTH_FILE" ]]; then
                echo "Using cached login creds..."
                AUTH="$(cat $REPO_AUTH_FILE)"

            elif [[ -f "$REPOSITORIES_FILE" ]]; then
                echo "Checking helm login creds..."
                # Parse the repo file
                eval $(parse_yaml $REPOSITORIES_FILE "nexuscred_")
                repocount=1
                
                while [[ ! -z $(eval echo '${nexuscred_'${repocount}'_name:-}') ]]; do
                    if [[ $(eval echo '$nexuscred_'${repocount}'_name') == "${REPO}" ]]; then
                        echo "Found credentials inside helm file"
                        AUTH="$(eval echo '$nexuscred_'${repocount}'_username'):$(eval echo '$nexuscred_'${repocount}'_password')"
                        break;
                    fi
                    repocount=$[$repocount+1]
                done
            fi
            if [[ -z "${AUTH:-}" ]]; then
                if [[ -z "$NEXUS_USERNAME" ]]; then
                    read -p "Username: " NEXUS_USERNAME
                fi
                if [[ -z "$NEXUS_PASSWORD" ]]; then
                    read -s -p "Password: " NEXUS_PASSWORD
                    echo
                fi
                AUTH="$NEXUS_USERNAME:$NEXUS_PASSWORD"
            fi
        fi

        if [[ -d "$CHART" ]]; then
            CHART_PACKAGE="$(helm package "$CHART" | cut -d":" -f2 | tr -d '[:space:]')"
        else
            CHART_PACKAGE="$CHART"
        fi

        echo "Pushing $CHART to repo $REPO_URL..."
        curl -is -u "$AUTH" "$REPO_URL" --upload-file "$CHART_PACKAGE" | indent
        echo "Done"
        ;;
esac

exit 0
