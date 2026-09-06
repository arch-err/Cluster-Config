# CoreDNS ownership

Talos bootstraps the CoreDNS Deployment and Service. The platform chart supplies the `kube-system/coredns` ConfigMap when `gateway.infra` is configured, at sync wave `-5`.

The current Corefile in `kubernetes/platform/networking/coredns/resources/coredns.yaml` contains:

- A-record templates for one-label `*.apps.home` names pointing to `10.10.10.200`.
- A-record templates for one-label `*.infra.home` names pointing to `10.10.10.201`.
- Empty successful AAAA responses for those names.
- Kubernetes service discovery, upstream forwarding, caching, and reload handling.

The old per-host `hosts` block has already been removed. There is no pending manual post-merge removal step. This config affects in-cluster DNS; LAN-client DNS must be configured separately.

Inspect the live ConfigMap with `kubectl -n kube-system get configmap coredns -o yaml`, then test both apps and infra lookups from an existing diagnostic pod. Confirm A records match the configured gateway IPs and inspect CoreDNS logs if reload fails. The documentation cleanup did not perform live DNS validation.
