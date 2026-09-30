set no-exit-message
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

kubernetes_dir := justfile_dir() + '/kubernetes'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`
nodes := `talosctl config info -o yaml | yq -e '.nodes | join(" ")'`

[private]
default:
    just bootstrap -l

[doc('Bootstrap the Talos cluster')]
[group('bootstrap')]
talos: talos-secret talos-apply talos-bootstrap (talos-kubeconfig "node")

[doc('Bootstrap apps into the Talos cluster')]
[group('bootstrap')]
apps: apps-ready apps-namespaces apps-secrets apps-crds apps-helm
    just log info "Cluster is bootstrapped — Flux will start syncing the Git repository"
    just log info "Once the kube-api LoadBalancer is up, run 'just bootstrap talos-kubeconfig' to switch to k8s.internal"

[private]
[script]
[working-directory('../talos')]
talos-secret:
    just log info "Generating talsecret"
    if [ ! -f talsecret.sops.yaml ]; then
        talosctl gen secrets -o - | sops --filename-override talsecret.sops.yaml --encrypt /dev/stdin > talsecret.sops.yaml
    fi

[private]
[script]
talos-apply:
    just log info "Applying talos config"
    for n in {{ nodes }}; do
        if ! op=$(just --yes talos apply-node "$n" --insecure 2>&1); then
            if [[ "$op" == *"certificate required"* ]]; then
                just log info "Talos already configured, skipping apply of config" node "$n"
                continue
            fi
            just log fatal "Failed to apply Talos configuration" node "$n" output "$op"
        fi
    done

[private]
[script]
talos-bootstrap:
    just log info "Bootstrapping talos"
    until op=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do
        just log info "Talos bootstrap in progress. Retrying in 10 seconds..."
        sleep 10
    done

# k8s.internal resolves to a Cilium LoadBalancer IP, so until Cilium is up use lb=node to target the controller directly.
[private]
[script]
talos-kubeconfig lb="cilium":
    just log info "Fetching kubeconfig"
    until talosctl kubeconfig -n "{{ controller }}" --force "{{ justfile_dir() }}"; do sleep 10; done
    if [[ "{{ lb }}" != "cilium" ]]; then
        kubectl config set-cluster "$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')" --server "https://{{ controller }}:6443"
    fi

[private]
[script]
apps-crds:
    just log info "Applying CRDs"
    if ! helmfile --file "{{ source_directory() }}/helmfile/crds.yaml" template --quiet | yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --force-conflicts --filename -; then
        just log fatal "Failed to apply crds"
    fi

[private]
[script]
apps-helm:
    just log info "Syncing helmfile"
    if ! helmfile --file "{{ source_directory() }}/helmfile/apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile"
    fi

[private]
[script]
apps-namespaces:
    just log info "Applying namespaces for apps"
    for app in "{{ kubernetes_dir }}/apps"/*/; do
        ns="$(basename "$app")"
        if kubectl get namespace "$ns" &>/dev/null; then
            just log info "Namespace already exists" namespace "$ns"
        elif kubectl create namespace "$ns" --dry-run=client -o yaml \
                | kubectl apply --server-side --filename - &>/dev/null; then
            just log info "Namespace applied" namespace "$ns"
        else
            just log fatal "Failed to apply namespace" namespace "$ns"
        fi
    done

[private]
[script]
apps-secrets:
    just log info "Applying secrets for apps"
    for secret in \
        "{{ source_directory() }}/github-deploy-key.sops.yaml" \
        "{{ source_directory() }}/sops-age.sops.yaml" \
        "{{ kubernetes_dir }}/components/sops/cluster-secrets.sops.yaml"
    do
        name="$(basename "$secret" .sops.yaml)"
        if sops exec-file "$secret" \
                "kubectl --namespace flux-system apply --server-side --filename {}" &>/dev/null; then
            just log info "Secret applied" resource "$name"
        else
            just log fatal "Failed to apply secret" resource "$name"
        fi
    done

# Wait until nodes register as Ready=False. They only become Ready=True once the CNI is healthy.
[private]
[script]
apps-ready:
    just log info "Waiting for nodes to register as Ready=False"
    if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
            just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..."
            sleep 5
        done
    fi
