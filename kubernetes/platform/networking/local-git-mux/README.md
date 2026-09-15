# Local Git protocol mux

`local-git-mux` preserves one hostname for HTTPS and SSH without exposing
Forgejo SSH publicly or terminating public TLS inside the cluster.

With local split DNS pointing `git.3rr.dev` at `10.10.10.203`:

- TCP 443 is passed through unchanged to Cloudflare's public edge. Cloudflare
  terminates TLS and returns through the existing Tunnel and public Gateway.
- TCP 22 is sent directly to `forgejo-ssh.forgejo.svc.cluster.local`.

Public DNS remains unchanged, so public HTTPS works while public SSH does not.
HAProxy uses explicit public resolvers for the Cloudflare backend to prevent
the split-DNS record from creating a proxy loop.

The LoadBalancer and NetworkPolicy admit only the cluster LAN
(`10.10.10.0/24`), trusted client LAN (`10.20.20.0/24`), and J's current Home
VPN address (`10.20.21.2/32`). Egress is default-denied and limited to the
declared DNS resolvers, `git.3rr.dev:443`, and the Forgejo SSH Service. HAProxy
runs non-root with a read-only rootfs and without a Kubernetes service-account
token.

The router DNS override is intentionally managed separately. Before adding it,
verify the mux with:

```bash
./scripts/verify-local-git-mux.sh
```
