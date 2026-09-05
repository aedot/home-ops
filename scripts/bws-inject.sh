#!/usr/bin/env bash
# bws-inject.sh — resolve bws://KEY tokens from Bitwarden Secrets Manager.
# Reads a file argument or stdin, writes the resolved content to stdout.
# The op-inject analogue for Bitwarden: scan for bws://KEY, substitute the
# secret whose "key" matches KEY within the (optional) BWS_PROJECT_ID project.
#
# Requires: BWS_ACCESS_TOKEN in env, `bws` and `jq` on PATH.
# Optional:  BWS_PROJECT_ID to scope the lookup to one project.
set -euo pipefail

content="$(cat "${1:-/dev/stdin}")"

if [[ "$content" == *"bws://"* ]]; then
    list_args=(secret list -o json)
    [[ -n "${BWS_PROJECT_ID:-}" ]] && list_args+=("$BWS_PROJECT_ID")

    declare -A secrets
    while IFS=$'\t' read -r key value; do
        secrets["$key"]="$value"
    done < <(bws "${list_args[@]}" | jq -r '.[] | [.key, .value] | @tsv')

    while [[ "$content" =~ (bws://[a-zA-Z0-9/_.-]+) ]]; do
        token="${BASH_REMATCH[1]}"
        key="${token#bws://}"
        if [[ -z "${secrets[$key]+x}" ]]; then
            echo "bws-inject: no secret named '$key'" >&2
            exit 1
        fi
        content="${content//"$token"/"${secrets[$key]}"}"
    done
fi

printf '%s' "$content"
