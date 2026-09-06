# Storage and data retention

The current configuration uses node-local storage. Kadalu is disabled in `infra.disabledComponents` and `extras.kadalu`; its configuration remains for historical/disabled services.

## Configured storage

| Storage | Location | Reclaim policy | Notes |
| --- | --- | --- | --- |
| `local-bulk` | NODE-2, `/var/mnt/bulk` on the Talos `bulk` user volume | `Retain` | Explicit opt-in; `WaitForFirstConsumer`; NODE-2 topology restriction |
| `local-path` | Selected node, `/opt/local-path-provisioner` | `Delete` | Explicit opt-in; `WaitForFirstConsumer`; no replication |
| Static local PVs | NODE-2, named paths such as `/var/mnt/bulk/media-library` and `/var/mnt/bulk/calibre-library` | Explicitly declared in each PV | Separate PV/PVC bindings expose shared directories to participating apps |
| `kadalu.replica2*` | Legacy distributed storage configuration | Legacy policy varies | Provisioner disabled; do not select for new workloads |

Sources: [local-bulk values](../kubernetes/values/infra/local-bulk.yaml), [local-path values](../kubernetes/values/infra/local-path-provisioner.yaml), [static resources](../kubernetes/platform/templates/extras.yaml), [Talos disk configuration](../talos/talconfig.yaml).

Local storage does not fail over to another node with its data. Backups provide recovery, not storage availability. Separate PVs referencing one host directory also require coordinating all writers and consumers.

## Retention policy

Irreplaceable user data must have a retained PV and a verified backup/restore procedure. `Retain` prevents automatic backend deletion when a claim is released; it does not protect against disk failure, application deletion of files, or manual cleanup.

For new valuable persistent data, choose retention declaratively. Do not rely on an after-deployment patch as the normal workflow. The database template still defaults to `kadalu.replica2-retain`; explicitly select the current intended class in every new `db.storage` block.

Changing a StorageClass definition does not migrate existing bound PVCs or prove their PV reclaim policy. Inspect the actual objects:

```sh
kubectl get pvc -A
kubectl get pv -o custom-columns=NAME:.metadata.name,NAMESPACE:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,CLASS:.spec.storageClassName,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase
```

## Retiring or restoring a service

Before removing resources, record each PVC's data disposition, backing PV/path, consumers, and verified backup. Review child and parent ArgoCD deletion policies separately. Preserve disabled configuration until its data dependencies are understood.

A retained, released PV may be rebound after its old claim ownership is resolved. Do not clear claim references or recreate PVCs blindly: first verify the underlying data and that no other workload still owns or writes it. Storage class changes on bound claims are not a file migration.

## Historical context

The earlier Kadalu setup suffered data loss when an application retirement deleted a claim backed by a `Delete` PV. That incident motivated retained PVs and explicit review of data disposition. The old detailed policy and configuration remain in Git history; their old PVC inventories and claims about live state are not current evidence.

See [backup status](backup-manual.md) before relying on the existing helper script.
