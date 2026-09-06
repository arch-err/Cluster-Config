# Kubernetes and GitOps

Talos provides Kubernetes and etcd on three control-plane nodes that also run workloads. Cilium provides the CNI, kube-proxy replacement, Gateway API integration, L2 announcements, and Hubble. ArgoCD manages the application layer through Helm.

## Network

Values below come from [talconfig.yaml](../talos/talconfig.yaml) and [infra.yaml](../kubernetes/infra.yaml).

| Endpoint | Address |
| --- | --- |
| Kubernetes API VIP | `10.10.10.170:6443` |
| NODE-1 / NODE-2 / NODE-3 | `10.10.10.171` / `.172` / `.173` |
| LoadBalancer address pool | `10.10.10.200`–`10.10.10.220` |
| Apps gateway, `*.apps.home` | `10.10.10.200` |
| Infra gateway, `*.infra.home` | `10.10.10.201` |
| External Docker host | `10.10.10.160` |

The gateways terminate HTTPS with separate wildcard certificates issued by the internal `home-ca` ClusterIssuer. External `*.home` services use TLS passthrough to the Docker host; see `external.services` in `infra.yaml` for the actual names. `rocky.infra.home` is a separate HTTPS-to-HTTP route to `10.10.10.160:3030`.

The platform chart owns the CoreDNS ConfigMap and synthesizes internal apps/infra DNS answers. LAN-client DNS and the external Docker host are outside this repository's Kubernetes reconciliation. See [CoreDNS](../kubernetes/manual/coredns/README.md).

## GitOps ownership

[Bootstrap ArgoCD values](../kubernetes/bootstrap/argocd.yaml) define four root Applications:

| Root | Source |
| --- | --- |
| `infra` | Local platform chart with `kubernetes/infra.yaml` |
| `apps` | Local platform chart with `kubernetes/apps.yaml` |
| `infra-secrets` | `kubernetes/secrets/infra/` |
| `apps-secrets` | `kubernetes/secrets/apps/` |

Each enabled component generates a child Application with an upstream Helm chart and values from this repository. Parent renders also contain routes, storage resources, OIDC bootstrap jobs, and database Cluster resources. ArgoCD's own runtime settings live in [its component values](../kubernetes/values/infra/argocd.yaml); editing bootstrap values alone does not update existing roots automatically.

The maintained manifests target `main`. Existing cluster roots may still target `v2`; follow the [cutover runbook](repository-state.md) before pruning it.

## Sync behavior

Components may set `syncWave`; otherwise their Application defaults to wave `0`. Supporting templates have their own waves. Child Applications use automated sync/self-heal, with `Prune=confirm` and `Delete=confirm` guards. Root policies are defined separately in bootstrap values. Never infer that every deletion is protected by a child's settings.

Several Gateway API differences are ignored at the whole-spec level, and child Applications use `RespectIgnoreDifferences=true`. A green sync status alone is therefore insufficient evidence that routes match Git; inspect rendered and live routing resources when changing them.

Fresh bootstrap ordering remains a known limitation: the CNPG Cluster template renders at wave `0`, while the n8n child Application is at wave `3`. PR #6 proposed a namespace-ordering fix but was closed without merging by user decision; the existing behavior is unchanged.

## Bootstrap status

`just install` runs `install-cilium`, `install-argocd`, then `deploy-age-key`. ArgoCD installation is split into CRD creation and application of bootstrap values.

These are retained operator recipes, **not a verified clean-rebuild procedure**. `install-cilium` still installs Gateway API CRDs at `v1.1.0`, while the GitOps Cilium chart constraint is `1.19.x`. Bootstrap Helm invocations do not pin the same versions as GitOps. Review that mismatch before rebuilding; this cleanup deliberately leaves all versions unchanged.

## Routine inspection

After loading the correct kubeconfig:

```sh
kubectl get nodes -o wide
kubectl -n argocd get applications
kubectl -n gateway-system get gateways
kubectl get httproutes,tlsroutes -A
kubectl get pvc -A
kubectl get pv
```

ArgoCD is at `https://argocd.infra.home`; Pocket ID is at `https://auth.apps.home`. Local ArgoCD admin login remains available for SSO recovery. See [manual ArgoCD setup](../kubernetes/manual/argocd/README.md).
