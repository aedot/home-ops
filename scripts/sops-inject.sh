#!/usr/bin/env bash
# sops-inject.sh — resolve sops://<yq-path> tokens from talos/talsecret.sops.yaml.
# Reads a file argument or stdin, writes the resolved content to stdout.
# The secret backend for the Talos machine config: scan for sops://<path> and
# substitute the value at that path in the decrypted talsecret bundle.
#
# Requires: `sops` (with the decryption key available) and `yq` on PATH.
set -euo pipefail

content="$(cat "${1:-/dev/stdin}")"

if [[ "$content" == *"sops://"* ]]; then
    root="$(cd "$(dirname "$0")/.." && pwd)"
    bundle="$(sops -d "$root/talos/talsecret.sops.yaml")"

    while [[ "$content" =~ (sops://[a-zA-Z0-9._-]+) ]]; do
        token="${BASH_REMATCH[1]}"
        path="${token#sops://}"
        value="$(printf '%s' "$bundle" | yq -r -e ".$path")"
        content="${content//"$token"/"$value"}"
    done
fi

printf '%s' "$content"
