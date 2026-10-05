#!/bin/bash
# parse input
project_version="$1"
if [ -z "$project_version" ]; then
    >&2 echo "project version was not provided"
    >&2 echo "usage: $0 <project-version>"
    exit 1
fi
# replace "@project-version@" with provided version in all toc files
echo "will set add-on version to all toc files: $project_version"
shopt -s globstar
for file in **/*.toc; do
    echo "setting version in $file"
    diff=$(mktemp)
    sed -i "s/@project-version@/$project_version/gw $diff" "$file"
    if [ -s $diff ]; then
        cat $diff
        rm $diff
    else
         >&2 echo "ERROR: @project-version@ not found in $file"
        exit 1
    fi
done
