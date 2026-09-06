# Service setup notes

Service-specific manual setup is documented beside the service:

- [Pocket ID enrollment and bootstrap token](../kubernetes/platform/identity/pocket-id/README.md)
- [ArgoCD identity and recovery](../kubernetes/platform/argocd/README.md)
- [Jellyfin setup](../kubernetes/services/jellyfin/README.md)
- [CoreDNS ownership](../kubernetes/platform/networking/coredns/README.md)

Add a service README only when there is useful service-specific setup or recovery information. Include prerequisites, manual state, verification, and backup/recovery locations. Cluster-wide procedures belong in `docs/`; credentials belong in encrypted secret files or the operator's credential store.
