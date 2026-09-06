# Cilium and Hubble TLS

Cilium's chart renders Hubble `Certificate` resources using `hubble.tls.auto.method: certmanager`. The namespaced `hubble-ca` Issuer in `kube-system` signs them using the existing Cilium CA. Cilium and Hubble continue mounting the same server/client Secrets; the chart no longer generates their contents during rendering.

## Ownership and recovery

- `infra-secrets` owns the encrypted `secrets/cilium-ca.yaml` SopsSecret. The operator maintains `cilium-ca`, preserving the original `ca.crt`/`ca.key` fields and supplying the same pair as `tls.crt`/`tls.key` for cert-manager.
- `infra` owns `resources/hubble-ca.yaml`, the namespaced Issuer.
- `cilium` owns the two chart-generated Certificates; cert-manager maintains `hubble-server-certs` and `hubble-relay-client-certs`.
- The three underlying Secrets are not directly tracked as Helm-generated Argo resources. Do not prune them as leftovers or restore their old Argo tracking annotations.

For recovery, make cert-manager and sops-secrets-operator available, restore the CA SopsSecret, wait for its Secret, apply the Issuer, then the Hubble Certificates. Verify the Issuer and Certificates are Ready and Hubble Relay can reach all nodes. Cilium networking bootstrap remains separate; do not introduce a cert-manager dependency into the initial CNI installation.

The CA is the existing trust root, valid until **2029-08-29**. cert-manager renews leaf certificates; its CA Issuer does **not** rotate this CA automatically. Plan CA replacement and trust migration before its expiry. Never replace the encrypted CA casually: existing Hubble clients and servers trust it.

## Migration validation

The approved migration preserves all non-certificate chart resources byte-for-byte at the manifest-object level, including pod templates. It replaces three generated Secret declarations with two Certificate declarations, retaining the live Secrets while transferring management. Leaf certificate issuance/rotation is within J's explicit approval; Cilium software upgrades and unrelated changes are not.

References: [Cilium Hubble TLS](https://docs.cilium.io/en/stable/observability/hubble/configuration/tls/), [cert-manager CA Issuer](https://cert-manager.io/docs/configuration/ca/).
