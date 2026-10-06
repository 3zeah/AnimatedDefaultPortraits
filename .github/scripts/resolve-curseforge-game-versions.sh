#!/bin/bash
# parse input
api_token="$1"
if [ -z "$api_token" ]; then
    >&2 echo "api token was not provided"
    >&2 echo "usage: $0 <api-token>"
    exit 1
fi
# map toc versions to game version id:s from curseforge
>&2 echo "getting all game versions from CurseForge"
set -x
all_game_versions=$(curl --location \
        --no-progress-meter --fail-with-body --retry 5 \
        --url "https://wow.curseforge.com/api/game/versions" \
        --header "X-Api-Token: $api_token" \
        --header "Accept: application/json" \
    ) || (>&2 echo "request fail"; >&2 echo "$all_game_versions"; exit 1)
set +x
echo "$all_game_versions" | >&2 jq

>&2 echo "getting interface versions from package toc files"
shopt -s globstar
for file in **/*.toc; do
    >&2 echo "getting interface versions from $file"
    line=$(cat "$file" | grep '## Interface:' | sed 's/## Interface://')
    line_count=$(echo "$line" | wc -l)
    if [[ $line_count > 1 ]]; then
        >&2 echo "ERROR: multiple line matches for interface versions:"
        >&2 echo "$line"
        exit 1
    fi
    file_interfaces=$(echo "$line" | xargs) # strip
    >&2 echo "found interface versions: $file_interfaces"
    if [[ -z $interfaces ]]; then
        interfaces="$file_interfaces"
    else
        if [[ $file_interfaces != $interfaces ]]; then
            >&2 echo "ERROR: interface-version conflict"
            >&2 echo "interfaces of $file did not match those of previous file"
            >&2 echo "this file had $interfaces"
            >&2 echo " previous had $interfaces"
            exit 1
        fi
    fi
done
if [[ -z $interfaces ]]; then
    >&2 echo "ERROR: no interface versions found"
    exit 1
fi
>&2 echo "using interface versions: $interfaces"

>&2 echo "mapping interface versions to CurseForge game versions"
game_versions=""
for interface in $interfaces; do
    >&2 echo "mapping interface $interface to CurseForge game version"
    id=""
    id=$(echo "$all_game_versions" | jq -c '.[]' | while read -r game_version; do
        api_version=$(echo "$game_version" | jq -r '.apiVersion')
        if [[ "$interface" == "$api_version" ]]; then
            >&2 echo "found matching game version for interface $interface:"
            echo "$game_version" | >&2 jq
            id=$(echo "$game_version" | jq -r '.id')
            echo "$id"
            exit 0
        fi
    done)
    if [[ -z $id ]]; then
        >&2 echo "ERROR: did not find game version for interface $interface"
        exit 1
    fi
    >&2 echo "mapped interface $interface to CurseForge game version $id"
    game_versions+="$id"$'\n'
done
# intentionally un-quoted: collapse to a single line for $GITHUB_OUTPUT
echo $game_versions
