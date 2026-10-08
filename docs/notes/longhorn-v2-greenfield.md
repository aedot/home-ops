# Rebuilding the cluster on Longhorn V2 (SPDK / NVMe-TCP)

> **Historical note.** Written for the migration from the old `talconfig.yaml` / VolSync setup. Paths and recipes below have since changed: Talos config is in `talos/*.j2`, backups use kopiur, the wipe recipe is `just talos reset-node-wipe-data <node>` and the extra kernel module is `vfio_pci`. Use it for the reasoning, not as a runbook.

This is a **greenfield** build: the cluster is destroyed and rebuilt with Longhorn
running **only** the V2 data engine. There is no in-place migration — application
data comes back from your existing backups (volsync → R2) into fresh V2 PVCs.

**Why V2:** it replaces the host `open-iscsi` frontend with in-kernel `nvme_tcp`,
and with V1 disabled there is **no iSCSI stack on the nodes at all**. The
"all PVCs stuck `attaching`" outage class (open-iscsi node-DB param rename on a
Talos upgrade — see [longhorn-iscsi-attaching.md](longhorn-iscsi-attaching.md))
becomes impossible.

---

## Layout for this cluster

Each node (`oya`, `aje`, `oba`) has:
- an **install disk** (OS), selected by serial in `talconfig.yaml`, and
- one **dedicated data disk** (serials `50026B7383…`).

Under V1 that data disk was a Talos `userVolume` formatted and mounted at
`/var/mnt/longhorn`. Under V2 it is left **raw** and handed to Longhorn as a
`block` disk. No RWX volumes exist in this cluster, so pure V2 is safe.

---

## What this PR changes (config already in the repo)

| File | Change |
|------|--------|
| `talos/patches/global/machine-sysctls.yaml` | `vm.nr_hugepages: "1024"` (2 GiB for SPDK) |
| `talos/patches/global/machine-kernel.yaml` | load `nvme_tcp` + `uio_pci_generic` |
| `talos/talconfig.yaml` | remove the `longhorn` `userVolume` per node; add per-node `node.longhorn.io/default-disks-config` annotation (raw `block` disk, by-id path) |
| `talos/patches/global/machine-kubelet.yaml` | drop the `/var/mnt/longhorn` bind-mount |
| `talos/patches/global/machine-nodelabel.yaml` | keep `create-default-disk: "config"`; disk config now per-node in talconfig |
| `kubernetes/.../longhorn/app/helmrelease.yaml` | `defaultDataEngine: v2`, `v1DataEngine: false`, `persistence.dataEngine: v2`; removed `defaultDataPath` |
| `kubernetes/.../longhorn/storageclass/snapshot.yaml` | `longhorn-snapshot` / `longhorn-cache` / snapclass → `dataEngine: v2` |

> ⚠️ **Disk `by-id` paths are per-node.** These are **NVMe** disks (not SATA, so
> no `wwn-0x…`). The annotations use the stable **EUI id** form
> `/dev/disk/by-id/nvme-eui.<WWID>`. Get each node's WWID with:
> ```sh
> talosctl get disks --insecure -n <node-ip>
> ```
> The data disk is the 1 TB **KINGSTON** (`nvme0n1`); take its `WWID` (e.g.
> `eui.00000000000000000026b7383951a375`) and set the path to
> `/dev/disk/by-id/nvme-<WWID>`. The **SPCC** disk is the OS/install disk — leave
> it alone.

---

## Rebuild procedure

### 1. Pre-flight (before destroying anything)
- Confirm every app's data is backed up and **restorable** — the rebuild relies
  entirely on volsync → R2. Spot-check at least one restore if you can.
- Record the Longhorn backup target and any volsync config that isn't in git.

### 2. Wipe & reinstall Talos
The plain `just talos reset` only wipes `STATE` + `EPHEMERAL` (system partitions
on the **install** disk) — it leaves the KINGSTON data disk `nvme0n1` with its
old `u-longhorn` xfs partition. Use the data-wiping variant so the disk comes up
raw for V2:

```sh
just talos reset-wipe-data        # resets all nodes AND wipes /dev/nvme0n1
```

Already reset without wiping? The nodes are in maintenance mode, so the data disk
is no longer held as a volume — wipe it directly (per node):

```sh
talosctl -n <node-ip> wipe disk nvme0n1 --insecure --drop-partition
# verify: talosctl -n <node-ip> get discoveredvolumes --insecure | grep nvme0n1
# want only "nvme0n1 disk" — no p1 / u-longhorn / xfs
```

Then generate config and bootstrap:

```sh
just talos generate-config        # talhelper genconfig
# apply config + bootstrap per your normal flow, ONE node at a time
```

> Apply and verify node-by-node (see §3–4) rather than all at once — a storage
> issue then affects one node, not the cluster.

### 3. Verify the V2 runtime on each node
```sh
export KUBECONFIG=./kubeconfig
N=oya   # repeat for aje, oba
POD=$(kubectl -n longhorn-system get pod -l app=longhorn-manager \
      --field-selector spec.nodeName=$N -o jsonpath='{.items[0].metadata.name}')

# HugePages (want HugePages_Total >= 1024)
kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- \
  sh -c 'grep -i hugepages /host/proc/meminfo'
# Kernel modules (want nvme_tcp + uio_pci_generic)
kubectl -n longhorn-system exec "$POD" -c longhorn-manager -- \
  sh -c 'grep -E "nvme_tcp|uio_pci_generic" /host/proc/modules'
```

### 4. Confirm the V2 block disk registered
```sh
kubectl -n longhorn-system get nodes.longhorn.io -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for n in d["items"]:
    for name,dk in (n["spec"].get("disks") or {}).items():
        print(n["metadata"]["name"], name, "type=", dk.get("diskType"),
              "path=", dk.get("path"), "sched=", dk.get("allowScheduling"))'
```
Every node should show exactly one `type=block` disk that is schedulable. If a
node shows no disk (or a `filesystem` one), the `by-id` path in `talconfig.yaml`
is wrong — fix it and re-apply.

Also confirm the engine picture is V2-only:
```sh
kubectl -n longhorn-system get instancemanager \
  -o custom-columns='NAME:.metadata.name,ENGINE:.spec.dataEngine,NODE:.spec.nodeID,STATE:.status.currentState'
# want: dataEngine=v2, Running, on every node — and NO v1 instance-managers
```

### 5. Smoke-test a V2 volume
```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: v2-smoke, namespace: default }
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: v2-smoke, namespace: default }
spec:
  containers:
    - name: c
      image: busybox
      command: ["sh","-c","echo ok > /data/test && sleep 3600"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: v2-smoke }
EOF

kubectl wait --for=condition=Ready pod/v2-smoke --timeout=120s
kubectl exec v2-smoke -- cat /data/test        # -> ok
# verify it's V2:
kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c '
import json,sys
for v in json.load(sys.stdin)["items"]:
    print(v["metadata"]["name"], v["spec"].get("dataEngine"), v["status"].get("robustness"))'
kubectl delete pod/v2-smoke pvc/v2-smoke
```

### 6. Bring the apps back
This branch disables every app namespace (each `kustomization.yaml` set to
`resources: []`, entries commented) so Longhorn V2 comes up clean with nothing
trying to mount volumes. Once §3–5 are green, **re-enable apps incrementally** —
uncomment a namespace's `ks.yaml` entries, let Flux reconcile, and restore data
via volsync into the fresh V2 PVCs. Watch that PVCs bind on the `longhorn`
(now V2) class and volumes report `healthy` before moving to the next app.

---

## Notes & things to review

- **CPU reservation:** the existing `guaranteedEngineManagerCPU` /
  `guaranteedReplicaManagerCPU` settings are V1-only and inert with V1 disabled.
  V2's SPDK poller reserves a core; review the V2 instance-manager CPU setting
  for Longhorn 1.12 and set it explicitly if you want to cap/guarantee it.
- **Feature parity:** confirmed no RWX in use. If you later need RWX, verify V2
  support in 1.12 before adding it — historically it was V1-only.
- **RAM cost:** HugePages permanently reserve 2 GiB per node.
- **Rollback:** to go back to V1, re-add the `userVolume` per node in
  `talconfig.yaml`, restore the `/var/mnt/longhorn` mount + `defaultDataPath`,
  set `defaultDataEngine: v1` / `v1DataEngine: true`, and flip the StorageClasses
  back to `dataEngine: v1`.

---

## Quick verification cheatsheet

```sh
export KUBECONFIG=./kubeconfig
# Volumes by data engine + robustness
kubectl -n longhorn-system get volumes.longhorn.io -o json | python3 -c '
import json,sys,collections
d=json.load(sys.stdin); c=collections.Counter()
for v in d["items"]:
    c[(v["spec"].get("dataEngine"), v["status"].get("robustness"))]+=1
for k,n in sorted(c.items()): print(n, k)'
```
