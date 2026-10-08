# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Kubernetes GitOps home lab repository. [Flux](https://fluxcd.io/) watches `kubernetes/` and reconciles the cluster state from Git. [Renovate](https://docs.renovatebot.com/) creates PRs for dependency updates. The cluster runs on [Talos Linux](https://www.talos.dev/) (three control-plane nodes that also run workloads) with [Longhorn](https://longhorn.io/) (v2 data engine only) for persistent storage. The repository is public.

## Common Commands

Tools are installed via `mise install` (see `.mise.toml`). Task automation uses `just`:

```bash
just -l                                   # list recipes (modules: bootstrap, kube, talos)
just kube reconcile                       # force Flux to pull the repo
just talos render-config <node-ip>        # render merged Talos machine config
just talos validate-config <node-ip>      # validate it

# Validate manifests (same check CI runs)
scripts/validate-manifests.sh

# Flux
flux get kustomizations -A
flux logs -f --all-namespaces

# Secrets (SOPS + age)
sops kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml      # edit
sops -d kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml   # view
```

## Architecture

### GitOps Flow

`kubernetes/flux/cluster/ks.yaml` defines the `cluster-apps` Flux Kustomization, which points at `./kubernetes/apps` and patches defaults into every child Kustomization (SOPS decryption, HelmRelease install/upgrade remediation, and the CNPG `init` bootstrap override). Each namespace directory has a top-level `kustomization.yaml` that typically:
1. Declares `components: [../../components/sops, ../../components/namespace]`
2. Lists `resources:` referencing one or more `ks.yaml` files

Each `ks.yaml` is a **Flux Kustomization** that points at an `./app` subdirectory containing the `HelmRelease`, its `OCIRepository` and related manifests.

### Namespace/App Layout

```
kubernetes/apps/<namespace>/
├── kustomization.yaml       # sops + namespace components, ks.yaml refs
└── <app>/
    ├── ks.yaml              # Flux Kustomization -> ./app; components, dependsOn, postBuild
    └── app/
        ├── kustomization.yaml
        ├── helmrelease.yaml     # usually bjw-s app-template via chartRef
        ├── ocirepository.yaml   # chart source, one per app
        ├── externalsecret.yaml  # secrets from Bitwarden Secrets Manager
        └── [httproute, networkpolicy, prometheusrule, grafanadashboard, ...]
```

### Reusable Components (`kubernetes/components/`)

Components are attached to a Flux Kustomization via the `components:` field in `ks.yaml` (not in the namespace-level `kustomization.yaml`), except `sops` and `namespace`, which are attached at namespace level:

- `namespace` - Namespace (with Pod Security `warn`/`audit` labels) plus Flux alerts
- `sops` - the `cluster-secrets` Secret used for `${VAR}` substitution
- `kopiur` - PVC with restore-on-create plus hourly snapshot policy and schedule (Kopia repository on the NAS)
- `postgres` - per-app CloudNativePG cluster `${APP}-db` with Barman backups to R2, local dump CronJobs, network policies. Label the app's Kustomization `components.postgres/cnpg: init` for a brand-new database. Set `PG_SUPERUSER: "true"` only if the app needs the superuser secret.
- `dragonfly` - Dragonfly (Redis-compatible) instance
- `gpu` - Intel GPU ResourceClaimTemplate (DRA); the namespace needs `resource.kubernetes.io/admin-access` (`media` and `home-automation` have it)
- `zeroscaler` - HPA that scales to zero when the NFS probe fails

### Variable Substitution

Flux injects cluster-wide variables (e.g. `${SECRET_DOMAIN}`) into manifests via:
```yaml
postBuild:
  substituteFrom:
    - name: cluster-secrets
      kind: Secret
```
Use `${VAR_NAME}` syntax in HelmRelease `values:`. Per-app values go under `postBuild.substitute` (e.g. `APP`). Use `$${VAR}` to leave a variable for the shell.

### Secret Management

- Secrets at rest: `*.sops.yaml` files encrypted with SOPS + age (`.sops.yaml`). Only `data`/`stringData` are encrypted for Kubernetes files. Never commit decrypted files.
- Runtime secrets: `ExternalSecret` resources use the `bitwarden` `ClusterSecretStore` (Bitwarden Secrets Manager) via the `external-secrets` operator.
- Renovate ignores `*.sops.*` files.
- Key material (`age.key`, `kubeconfig`, `talosconfig`, `github*.key|pem|txt`, `cloudflare-tunnel.json`) lives in the working tree but is gitignored. Never read, print or edit it.

### DNS / Ingress

Two ExternalDNS instances: **internal** (UniFi, gateway `envoy-internal`) and **external** (Cloudflare, gateway `envoy-external`). Ingress is Envoy Gateway (HTTPRoute). Cloudflared provides the tunnel to `envoy-external`. The external gateway only accepts routes from an allow-list of namespaces (see `kubernetes/apps/network/envoy-gateway/app/envoy.yaml`); add a namespace there before exposing an app from a new one.

### Backups

- PVCs: kopiur snapshots to a Kopia repository on the NAS (`ClusterRepository` `nas`). PVCs created by the `kopiur` component carry `kustomize.toolkit.fluxcd.io/prune: disabled`.
- Postgres: CNPG Barman WAL and base backups to Cloudflare R2, plus 12-hourly logical dumps to NFS.

### Bootstrap

`just bootstrap talos` then `just bootstrap apps`. Helmfile in `bootstrap/helmfile/` installs: Cilium, CoreDNS, Spegel, cert-manager, external-secrets, flux-operator, flux-instance (CRDs are applied first from `crds.yaml`). Chart versions and values are read from the same `ocirepository.yaml` and `helmrelease.yaml` Flux uses.

### Talos Configuration

Node OS config lives in `talos/` as Jinja templates (`cluster.yaml.j2`, `controlplane.yaml.j2`, `networking.yaml.j2`, `nodes/<ip>.yaml.j2`) merged by `just talos render-config`. Secrets use `sops://<path>` tokens resolved by `scripts/sops-inject.sh` from `talos/talsecret.sops.yaml`. OS and Kubernetes upgrades are driven by `tuppr` from `kubernetes/apps/system-upgrade/tuppr/upgrades/`.

## CI (GitHub Actions)

- **validate** - on PRs: builds every Flux Kustomization path and runs `kubeconform` (`scripts/validate-manifests.sh`), and runs `zizmor` on workflows
- **flate** - on PRs touching `kubernetes/**`: posts HelmRelease and Kustomization diffs as PR comments
- **image-pull** - on same-repo PRs: pre-pulls changed images onto a node using the in-cluster runner. Never run fork code on that runner; it holds Talos credentials.
- **renovate**, **label-sync**, **tag** - maintenance

## Adding a New Application

1. Create `kubernetes/apps/<namespace>/<app>/app/` with `helmrelease.yaml`, `ocirepository.yaml`, `kustomization.yaml` (copy a similar app).
2. Create `kubernetes/apps/<namespace>/<app>/ks.yaml` as a Flux Kustomization referencing `./app`, with `dependsOn`, `components` and `postBuild` as needed. Apps using `kopiur` depend on `kopiur-repository`; apps with `ExternalSecret`s depend on `bitwarden-stores`.
3. Add `- ./<app>/ks.yaml` to the namespace's top-level `kustomization.yaml`.
4. If a new namespace, create `kubernetes/apps/<namespace>/kustomization.yaml` with the sops and namespace components.
5. Pin images by digest, set resource requests and a memory limit, and set container `securityContext` (non-root, read-only root filesystem, drop all capabilities) wherever the image allows.
6. Run `scripts/validate-manifests.sh`, then commit and push. Flux reconciles automatically.
