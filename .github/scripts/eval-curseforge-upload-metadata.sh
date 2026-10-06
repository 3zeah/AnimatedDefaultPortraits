#!/bin/bash
# parse input
release_name="$1"
if [ -z "$release_name" ]; then
    >&2 echo "release name was not provided"
    >&2 echo "usage: $0 <release-name> <release-notes> <game-versions> <package-name>"
    exit 1
fi
release_notes="$2"
if [ -z "$release_notes" ]; then
    >&2 echo "release notes was not provided"
    >&2 echo "usage: $0 <release-name> <release-notes> <game-versions> <package-name>"
    exit 1
fi
game_versions="$3"
if [ -z "$game_versions" ]; then
    >&2 echo "game versions were not provided"
    >&2 echo "usage: $0 <release-name> <release-notes> <game-versions> <package-name>"
    exit 1
fi
package_name="$4"
if [ -z "$package_name" ]; then
    >&2 echo "package name was not provided"
    >&2 echo "usage: $0 <release-name> <release-notes> <game-versions> <package-name>"
    exit 1
fi
# evaluate the metadata field used to upload the package to curseforge
>&2 echo "uploading $package_name to CurseForge as $release_name"
>&2 echo "have following release notes:"
>&2 echo " === BEGIN RELEASE NOTES ==="
>&2 echo "$release_notes"
>&2 echo " === END RELEASE NOTES ==="
>&2 echo ""
game_versions_json=$(jq -ncM --arg s "$game_versions" '($s|split(" ")|map(tonumber))')
>&2 echo "have these game versions (as json): $game_versions_json"
>&2 echo "have following package:"
>&2 ls -lsh "$package_name"
>&2 echo ""
metadata_template=$(echo '{
    "displayName": $displayName,
    "changelog": $changelog,
    "changelogType": "markdown",
    "gameVersions": $gameVersions,
    "isMarkedForManualRelease": true
}')
metadata=$(jq -nc \
    --arg displayName "$release_name" \
    --arg changelog "$release_notes" \
    --argjson gameVersions "$game_versions_json" \
    "$metadata_template" \
)
>&2 echo "will send following metadata:"
echo "$metadata" | >&2 jq
echo "$metadata"
