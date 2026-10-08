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

## Rollout order

1. **selfhosted** (this change). Only cross-namespace sources seen: CoreDNS, Envoy, Prometheus, node probes.
2. **security** (Pocket-ID), **downloads**. Same sources. qBittorrent and SABnzbd also receive replies from the VPN VLAN only on the Multus interface.
3. **media**. Add `kubernetes/components/netpol/examples/plex.yaml` first: Plex is a LoadBalancer service reached from the LAN and the internet as `world`.
4. **home-automation**. Verify Home Assistant, Scrypted and Matter before enabling; they depend on the Multus interface for devices.
5. **dbms**. Add `examples/mosquitto.yaml` first (LAN devices and home-automation clients). Dragonfly operator traffic is already covered by the Dragonfly component.
6. Infrastructure namespaces (`flux-system`, `cert-manager`, `external-secrets`, `cnpg-system`, `kopiur-system`, `system-upgrade`, `actions-runner-system`) need webhook and controller-specific rules. Do them last, one at a time.

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
