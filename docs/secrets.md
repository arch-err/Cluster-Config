# Secrets

This repository uses SOPS with age. `.envrc` selects `~/.config/sops/age/cluster-config.txt` as `SOPS_AGE_KEY_FILE` and `talos/clusterconfig/kubeconfig` as `KUBECONFIG`.

## Stored in Git

| Location | Contents |
| --- | --- |
| `talos/talsecret.sops.yaml` | Encrypted Talos cluster secrets used during generation |
| `kubernetes/secrets/infra/` | Encrypted SopsSecret resources for infrastructure |
| `kubernetes/secrets/apps/` | Encrypted SopsSecret resources for applications |
| `talos/.sops.yaml`, `kubernetes/.sops.yaml` | Public recipients and encryption rules |

The four ArgoCD root Applications include separate directory sources for infra and app secrets. sops-secrets-operator decrypts SopsSecrets into ordinary Kubernetes Secrets. Keep resource metadata readable for Kubernetes and encrypt secret payloads using the existing file's structure.

Edit an existing file with SOPS from the matching configuration directory, for example:

```sh
source .envrc
cd kubernetes
sops secrets/infra/n8n-secrets.yaml
```

For a new SopsSecret, follow an existing manifest's structure and encrypt its `stringData` payload before staging it. Review the staged diff to ensure no credential values are plaintext. Never commit generated machine configs, kubeconfigs, private age keys, or decrypted copies.

## Outside Git

- **Private age key:** supplied by the operator. `just deploy-age-key` creates `sops-age-key` in the operator namespace; it does not generate a recovery copy of the key.
- **Pocket ID API token:** regular Secret `pocket-id-api-token` in namespace `pocket-id`, key `POCKET_ID_API_TOKEN`. The token is manually supplied and intentionally absent from Git; see [Pocket ID](../kubernetes/manual/pocket-id/README.md).
- **OIDC client credentials:** created by platform bootstrap jobs in each application's namespace.
- **CNPG database credentials:** managed by the database operator.
- **Application state and enrollment:** generally stored on persistent volumes, not reconstructed by SOPS alone.

The file `kubernetes/secrets/home-root-ca.yaml` sits outside both root secret directories and is not selected by those directory sources. The managed CA manifest is `kubernetes/secrets/infra/home-root-ca.yaml`. The outside copy is retained pending a separate provenance review; do not mistake it for the active source.

A recovery plan needs the private age key plus database/application backups and manual bootstrap credentials. An encrypted Git archive alone is insufficient.
