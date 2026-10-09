# Network policy rollout

Cilium enforces policy, but until now only the Postgres and Dragonfly components, Longhorn and Teslamate had any. The `netpol` component adds an **ingress** baseline per namespace. Egress is a later phase.

## What the baseline allows

Derived from Hubble flows (about 14k flows across all nodes), for the app namespaces:

| Source | Why |
|--------|-----|
| Same namespace | Apps talking to their own DB, cache and sidecars |
| `host`, `remote-node`, `kube-apiserver` entities | Kubelet probes and node-local traffic (567 of the observed flows) |
| `observability` namespace | Prometheus scrapes, Gatus, blackbox-exporter, Grafana datasources |
| CoreDNS (`k8s-app=kube-dns`) | Cilium sees DNS replies as new flows; the Postgres component already needed this |
| Envoy proxies in `network` | HTTPRoute backends (`ingress-gateway` policy) |

Not covered: pod secondary interfaces from Multus (IoT and VPN VLANs) bypass Cilium. Home Assistant, Scrypted, Matter and the VPN downloaders are only partly protected until their primary interface is the only path in.

## Rollout status

Enforced: `selfhosted`, `downloads`, `media`, `home-automation`, `dbms` (once its PR merges). `security` is empty (Pocket-ID is disabled). Not yet: the infrastructure namespaces (`flux-system`, `cert-manager`, `external-secrets`, `cnpg-system`, `kopiur-system`, `system-upgrade`, `actions-runner-system`, `longhorn-system`, `kube-system`, `network`, `observability`), which need webhook and controller-specific rules. Do them one at a time, last.

Lessons from the rollout, to repeat for any namespace:

- Cilium here does not treat the replies to a connection a pod opens as part of that connection, so **an ingress baseline drops replies from other namespaces** (CoreDNS, Mosquitto, Sonarr and Radarr, the Dragonfly instances). Allow them by identity: a `CiliumNetworkPolicy` on the pod that opens the connection, `fromEndpoints` the service it calls. An allow-all egress policy was tried to make Cilium track these connections and made no difference, so it was removed.
- Services reached through a LoadBalancer address arrive as `world` (Plex, Mosquitto): allow `world` on the specific port.
- Traffic on Multus secondary interfaces is not subject to Cilium policy at all (Home Assistant, ESPHome, Matter, Scrypted IoT side; qBittorrent VPN side).
- A short Hubble buffer cannot see slow or long-lived connections. Run a live watch of the namespace boundary for the full window before merging, and then check `just kube drops <namespace>`.

## Applying and checking a namespace

1. Add `- ../../components/netpol` to the namespace's `kustomization.yaml`.
2. Merge, then watch for drops for a few minutes and over a full probe cycle:
   ```fish
   just kube drops <namespace>
   ```
3. Any `DROPPED` line means a legitimate source is missing from the baseline. Add a narrow rule (specific labels and ports), not a wider baseline.
4. Roll back by removing the component line; Flux prunes the policies.

Things to confirm while watching `selfhosted`: Grafana reaching the Teslamate database, the kopiur controller talking to mover pods, and Gatus probes. None were seen in the capture, but they may be periodic.

## Next phases

- Egress allow-lists for the internet-facing apps (Home Assistant, Plex, Seerr, Pocket-ID, Gramps Web): DNS, the database, and the specific upstream hosts.
- A policy that keeps pods off the node's metrics ports (etcd `:2381`, kube-scheduler and controller-manager) except from Prometheus.
- Move the Postgres and Dragonfly NetworkPolicies to this component once every namespace has the baseline.
