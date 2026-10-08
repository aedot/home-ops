#!/usr/bin/env bash
# Builds every Flux Kustomization path under kubernetes/apps and validates the
# rendered output against the CRD schemas. Secrets are skipped because SOPS
# files carry a top-level `sops` key that the Secret schema rejects.
set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"

schema_location='https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
status=0
checked=0

mapfile -t paths < <(
    yq -r 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .spec.path' \
        kubernetes/apps/*/*/ks.yaml | grep '^\./' | sort -u
)

for path in "${paths[@]}"; do
    # Flux generates a kustomization.yaml for directories that lack one.
    if [[ ! -f "${path}/kustomization.yaml" ]]; then
        echo "skip (no kustomization.yaml): ${path}"
        continue
    fi

    checked=$((checked + 1))

    if ! rendered=$(kustomize build "${path}" 2>&1); then
        echo "BUILD FAILED: ${path}"
        echo "${rendered}" | head -10
        status=1
        continue
    fi

    # Flux substitutes ${SECRET_DOMAIN} at apply time; use a valid hostname here.
    if ! result=$(echo "${rendered}" \
        | sed 's/\${SECRET_DOMAIN}/example.com/g' \
        | kubeconform -strict -skip Secret -summary \
            -schema-location default -schema-location "${schema_location}" 2>&1); then
        echo "SCHEMA FAILED: ${path}"
        echo "${result}" | head -10
        status=1
    fi
done

echo "Checked ${checked} paths"
exit "${status}"
