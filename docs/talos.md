# Talos

[talos/talconfig.yaml](../talos/talconfig.yaml) is the source for Talhelper generation. It currently declares Talos `v1.12.4` and Kubernetes `v1.34.0`; these are configured versions, not independently observed running versions.

## Nodes and storage

All three nodes are control-plane nodes with workload scheduling enabled. The API VIP is `10.10.10.170`; NODE-1 through NODE-3 use `10.10.10.171` through `.173`. Install disks are `/dev/nvme0n1`.

NODE-2 also declares the `bulk` UserVolumeConfig. It selects the external disk by its persistent USB by-id identity, provisions an XFS partition, and mounts it at `/var/mnt/bulk`. See [storage](pvc-reclaim-policy.md) before changing disk configuration. The old Kadalu settings and exemptions remain in the repository for historical configurations; Kadalu is disabled in its service declaration.

Global patches disable kube-proxy and the default CNI, enable kubelet serving-certificate rotation and user namespaces, and configure metrics listeners and restricted Pod Security defaults. Read the YAML for the complete exemptions and node-specific settings.

## Local prerequisites

The justfile uses `talhelper`, `talosctl`, `kubectl`, Helm, SOPS/age, and standard shell utilities. PXE boot additionally uses Podman, `sudo`, `nc`, and the wired interface configured as `booter_interface`. That interface and the node MAC addresses are operator-specific.

Load `.envrc` to select the repository's age key and generated kubeconfig paths. The private key and generated machine configs are local; they are not recoverable from a Git clone alone.

```sh
source .envrc
just generate
```

Generation writes into `talos/clusterconfig/`, including machine configuration and Talos client configuration. Fetching kubeconfig is a separate bootstrap step. Generated files are ignored by Git.

## Commands and their effects

| Command | Effect |
| --- | --- |
| `just generate` | Generate local machine configurations |
| `just status` | Inspect Talos and Kubernetes status |
| `just dashboard 1` | Open Talos dashboard for NODE-1 |
| `just services` / `just containers` | Inspect node services / Kubernetes containers |
| `just bootstrap` | Wipe/PXE boot nodes, apply configs, bootstrap etcd, and fetch kubeconfig |
| `just install` | Install the Kubernetes networking/GitOps layer |
| `just reset` | Destructive reset, with a typed confirmation |
| `just reinstall` | Uninstall and reinstall Kubernetes infrastructure |

`bootstrap` invokes `scripts/booter-wipe`; it is not a routine refresh command. `reinstall` and uninstall recipes delete infrastructure and include finalizer removal. Inspect their definitions and establish a restore path before use.

A fresh-cluster rebuild has not been validated by the repository cleanup. Resolve the [bootstrap gaps](repository-state.md) and verify backups before treating these recipes as a recovery procedure.
