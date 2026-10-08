# home-ops Architecture

How the pieces fit together. For day-to-day commands and conventions see [AGENTS.md](AGENTS.md); for component details see the README next to each component.

## Layers

| Layer | What | Where |
|-------|------|-------|
| OS | Talos Linux, three control-plane nodes that also run workloads, one OS disk and one dedicated NVMe data disk each | `talos/` |
| Networking | Cilium (kube-proxy replacement, native routing, BGP control plane, Hubble), Multus for IoT and VPN VLANs, Envoy Gateway, Cloudflare tunnel | `kubernetes/apps/kube-system`, `kubernetes/apps/network` |
| Storage | Longhorn, v2 (SPDK/NVMe-TCP) data engine only, 3 replicas; `longhorn-postgres` class uses 1 replica because CNPG replicates | `kubernetes/apps/longhorn-system` |
| GitOps | Flux (via flux-operator and flux-instance) syncing `kubernetes/flux/cluster` from `main` | `kubernetes/flux`, `kubernetes/apps/flux-system` |
| Secrets | SOPS + age for bootstrap secrets, External Secrets with Bitwarden Secrets Manager at runtime | `kubernetes/apps/external-secrets` |
| Data services | CloudNativePG (per-app clusters), Dragonfly operator, Mosquitto | `kubernetes/components`, `kubernetes/apps/dbms`, `kubernetes/apps/cnpg-system` |
| Backups | kopiur (PVCs to a Kopia repo on the NAS), Barman to Cloudflare R2 (Postgres), logical dumps to NFS | `kubernetes/apps/kopiur-system`, `kubernetes/components` |
| Observability | kube-prometheus-stack, Grafana (operator), VictoriaLogs, Fluent Bit, Gatus, exporters | `kubernetes/apps/observability` |
| Upgrades | Renovate PRs; `tuppr` rolls Talos and Kubernetes upgrades gated on Longhorn and kopiur health | `kubernetes/apps/system-upgrade` |
| CI | GitHub Actions (validate, flate, image-pull) with an in-cluster runner scale set | `.github/workflows`, `kubernetes/apps/actions-runner-system` |

Tool versions are pinned in [.mise.toml](.mise.toml); chart and image versions live next to each app.

## Deployment flow

1. A change is pushed to a branch and a PR is opened against `main`.
2. `validate` builds every Flux Kustomization path and runs `kubeconform`; `flate` comments the rendered diff; `image-pull` pre-pulls new images on a node for same-repo PRs.
3. After merge, the GitHub webhook (or the interval) makes Flux pull `main`.
4. `cluster-apps` applies `kubernetes/apps`. Each app's Flux Kustomization decrypts SOPS files, substitutes `${VAR}`s from the `cluster-secrets` Secret, and applies its `HelmRelease`. Helm install and upgrade remediation defaults are patched in from `kubernetes/flux/cluster/ks.yaml`.
5. `dependsOn` orders apps behind Longhorn, `bitwarden-stores` (so ExternalSecrets resolve) and `kopiur-repository` (so PVC restores resolve). CRDs for the bootstrap-time operators are installed out of band by `bootstrap/helmfile/crds.yaml`, so most apps do not depend on the operator that owns a CRD.

## Update flow

Renovate (hourly workflow) opens PRs from `.renovaterc.json5` and `.renovate/`. Container image digests for trusted images, a few chart and CRD updates and GitHub Actions auto-merge as PRs once checks pass; everything else waits for review. Talos and Kubernetes version bumps in `tuppr` resources trigger rolling upgrades after merge.

## Security model

- **Repository is public.** Anything committed is world-readable; secrets are SOPS-encrypted and runtime secrets never enter Git.
- **CI trust.** The in-cluster runner holds Talos `os:admin` credentials. Fork PRs require approval for all outside contributors, and the `image-pull` job that uses the runner only runs for same-repo PRs. The runner ServiceAccount has a namespaced Role only.
- **Network.** Cilium enforces NetworkPolicy, but policies exist only for the Postgres and Dragonfly components, Longhorn and Teslamate. There is no default-deny yet; Hubble is enabled to observe flows before adding it. The external gateway accepts routes only from an allow-list of namespaces.
- **Pod security.** Namespaces created from the `namespace` component carry Pod Security `warn` and `audit` labels at `restricted`; nothing is enforced. Most app containers drop capabilities, run non-root and use a read-only root filesystem (see the exceptions in `REVIEW.md`).
- **Secrets.** Kubernetes secrets are encrypted at rest in etcd (secretbox). The `bitwarden` ClusterSecretStore is not scoped per namespace.

## Disaster recovery

| Scenario | Recovery |
|----------|----------|
| Cluster lost | `just bootstrap talos`, then `just bootstrap apps`; Flux restores everything from Git. PVCs restore from kopiur on first create; Postgres clusters recover from Barman. |
| Single app data lost | Delete the PVC; Flux recreates it and kopiur restores the latest snapshot. |
| Postgres lost | Remove the `components.postgres/cnpg: init` label (it is only for brand-new databases) so the cluster bootstraps from the Barman archive, or restore a logical dump with the `<app>-postgres-restore` CronJob. |
| NAS lost | PVC snapshots and logical dumps are gone; Postgres WAL and base backups in R2 survive. An off-site copy of the Kopia repository is an open item. |
| Lost age key | `*.sops.yaml` files cannot be decrypted. Keep an offline backup of the key. |

## Tools used in this repository

mise (tool versions), just (tasks), kustomize and kubeconform (validation), SOPS and age, talosctl, flux, helmfile (bootstrap only), lefthook (git hooks), zizmor (workflow audit).
