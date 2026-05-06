# coredns

CoreDNS is laid down by Talos at bootstrap and never re-reconciled — the live `coredns` ConfigMap in `kube-system` carries no `app.kubernetes.io/managed-by` label, and the historical `kubectl edit` `hosts {}` drift survived multiple sessions without being clobbered. We take ownership of the ConfigMap via the platform chart (`platform/templates/extras.yaml`, gated on `.Values.gateway.infra` so it only renders in the infra-side platform render).

## what we own

- ConfigMap `coredns` in `kube-system` — the Corefile.

## what we DO NOT own

- The `coredns` Deployment + Service. Both are Talos-managed. We rely on Talos's volume mount of the `coredns` cm at `/etc/coredns/Corefile`, and on CoreDNS's `reload` plugin to pick up cm changes without a pod restart.

## what the Corefile does (beyond Talos's default)

- `template ANY A apps.home` — synthesizes A records for any `<svc>.apps.home` → apps gateway IP (`10.10.10.200`), `fallthrough` so unrelated queries (AAAA, NS, etc.) continue down the plugin chain.
- `template ANY A infra.home` — same for `<svc>.infra.home` → infra gateway IP (`10.10.10.201`).
- Legacy `hosts {}` block — kept as belt-and-suspenders during the cutover. **Remove post-merge** once the template plugins are verified (see "post-merge cleanup" below).

This makes adding a new in-cluster-resolvable hostname zero-cost: ship the app, route it through the gateway, done. No more per-app `kubectl edit cm coredns`.

## post-merge cleanup

Once this lands on `v2` and ArgoCD has reconciled, verify the template plugin is answering:

```bash
kubectl run --rm test --image=busybox --restart=Never -- nslookup <some-new-svc>.apps.home
# expect: 10.10.10.200
```

Then optionally remove the `hosts {}` belt-and-suspenders block. Edit `kubernetes/platform/templates/extras.yaml`, drop the block, commit. Cost of leaving it forever: ~6 lines of YAML, no functional downside.

## rebuild from scratch

If the cluster is wiped:

1. Talos comes up, lays down its default `coredns` cm with no `hosts {}` and no template plugins.
2. ArgoCD's `infra` root app syncs the platform chart, which renders this ConfigMap with `argocd.argoproj.io/sync-wave: "-5"` (early).
3. ServerSideApply takes ownership from Talos (force-conflict not needed; Talos doesn't reconcile).
4. CoreDNS pods hot-reload via the `reload` plugin; no manual restart.

Total: zero manual steps post-Talos-bootstrap. This file exists for explanatory value, not as a runbook.

## verification

```bash
# the cm
kubectl -n kube-system get cm coredns -o yaml | grep -A 5 'template ANY'

# a live lookup from inside the cluster
kubectl run --rm dnstest --image=busybox --restart=Never -- nslookup auth.apps.home
# expect: 10.10.10.200

kubectl run --rm dnstest --image=busybox --restart=Never -- nslookup grafana.infra.home
# expect: 10.10.10.201
```
