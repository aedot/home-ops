# Longhorn notes

Longhorn runs the **v2 (SPDK) data engine only**. Each node's dedicated NVMe data disk is a raw Talos volume (`longhornv2`, see `talos/cluster.yaml.j2`) that is handed to Longhorn as a block disk through the `node.longhorn.io/default-disks-config` node annotation. There is no host path or filesystem disk.

### Longhorn not scheduling on a node after a rebuild

Check that the node annotation is present and the disk is registered:

```sh
kubectl get node <node> -o jsonpath='{.metadata.annotations.node\.longhorn\.io/default-disks-config}'
kubectl -n longhorn-system get nodes.longhorn.io <node> -o yaml | yq '.spec.disks'
```

### Wiping a data disk before re-adding a node

Wipe the data disk from Talos, not from a pod:

```sh
just talos reset-node-wipe-data <node-ip>
```

This destroys the node's Longhorn data. Confirm the volumes have healthy replicas on the other nodes first.

See also `docs/notes/` for the v2 engine incident and the iSCSI attach outage.
