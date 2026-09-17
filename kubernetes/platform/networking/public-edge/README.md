# Public edge

Cloudflare Tunnel is the only Internet path into the cluster. It terminates at
the dedicated HTTP-only `public` Gateway; only namespaces labelled
`exposure=public` may attach routes. The generated Gateway LoadBalancer has no
NodePort and accepts its LAN VIP only from cluster Pod CIDRs.

Any component whose route selects `gateway: public` automatically receives the
public exposure and restricted Pod Security namespace labels. A cluster-wide
Cilium policy then permits ingress only from the Gateway and blocks access to
nodes, private networks, link-local space, and other cluster workloads. Public
pods retain DNS and outbound HTTP(S) access for ordinary application needs.
Workloads with a dedicated policy can opt out of that general egress; Forgejo
uses one to permit only DNS, its PostgreSQL instance, and public Pocket ID.

Public namespaces may only expose selector-backed Services. Admission rejects
`ExternalName`, selectorless Services, and user-managed EndpointSlices there, so
a public route cannot smuggle the Gateway toward a private pod IP through a
hand-written backend.

The Cloudflare source-IP restriction is deliberately held at Cloudflare and is
not injected into workloads. The tunnel token is stored as a SOPS-encrypted
`SopsSecret` in `secrets/cloudflared.yaml`.

Add a public service through the normal component route shape:

```yaml
route:
  hostname: example.3rr.dev
  gateway: public
  service: example
  port: 8080
```

Run `scripts/verify-public-edge.sh` after deployment. The script tests the
Gateway, accepted/rejected routes, Internet egress, and blocked cluster, node,
and LAN destinations from an ephemeral restricted pod.

Cloudflare provisioning is split so DNS cannot publish before the connector and
cluster checks succeed:

```bash
scripts/configure-cloudflare-public-edge.sh prepare
scripts/verify-public-edge.sh
scripts/configure-cloudflare-public-edge.sh publish
```

`prepare` creates or reuses the `homelab-public` tunnel, updates its wildcard
ingress, encrypts the connector token, and limits the whole zone to the current
public IPv4 through WAF. `publish` refuses to create wildcard DNS unless the
tunnel is healthy and the WAF still matches the current address. `disable`
removes only DNS owned by this tunnel.

`prepare` also reconciles the Free-plan rate-limit slot: more than five requests
to `/user/login` from one source in ten seconds triggers a Managed Challenge.
The rule is deliberately path-only because the Free plan cannot use hostname in
its rate-limit expression; Git HTTP, LFS, API, and static traffic are excluded.
Run `scripts/configure-cloudflare-public-edge.sh rate-limit` to reconcile only
that rule without rewriting the tunnel connector configuration.
