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

Cloudflare blocks the whole zone outside the EU member states and United
States. The restriction stays at the edge and is not injected into workloads.
Cloudflare's Free Managed Ruleset is deployed as the baseline WAF and the
minimum accepted client TLS version is 1.2. The tunnel token is stored as a
SOPS-encrypted `SopsSecret` in `secrets/cloudflared.yaml`.

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
ingress, encrypts the connector token, and reconciles the edge hardening.
`harden` (or `waf`) reconciles the geographic rule, Cloudflare Free Managed
Ruleset, login rate limit, and minimum TLS version without rewriting the tunnel
configuration. `publish` refuses to create wildcard DNS unless the tunnel is
healthy and the geographic rule exactly matches the declared country set.
`disable` removes only DNS owned by this tunnel.

The Free-plan rate-limit slot protects Pocket ID's passkey login exchange. More
than ten requests from one source to `/api/webauthn/login/…` in ten seconds
triggers a ten-second block. The rule is deliberately path-only because the
Free plan cannot use hostname in its rate-limit expression; ordinary app, API,
and static traffic is excluded. Run
`scripts/configure-cloudflare-public-edge.sh rate-limit` to reconcile only that
rule.

Bot Fight Mode is deliberately disabled. It applies to the whole zone and
cannot be skipped with a WAF rule, which makes it unsafe for machine-to-machine
endpoints such as MyrCTF telemetry.
