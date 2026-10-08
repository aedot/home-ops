set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[private]
default:
    just kube -l

[doc('Force Flux to pull in changes from your Git repository')]
[group('kube')]
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

[doc('Show traffic dropped by network policy in a namespace (needs Hubble)')]
[group('kube')]
drops namespace *args:
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe \
        --server "$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}'):80" \
        --verdict DROPPED --namespace {{ namespace }} {{ args }}
