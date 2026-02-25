# Secrets Management

Secrets are encrypted using [SOPS](https://github.com/mozilla/sops) with [age](https://github.com/FiloSottile/age) encryption.

## GitOps-Managed Secrets

All secrets are managed via GitOps using **SopsSecret** custom resources:

| ArgoCD App | Path | Purpose |
|------------|------|---------|
| `infra-secrets` | `kubernetes/secrets/infra/` | Infrastructure secrets (root CA, etc.) |
| `apps-secrets` | `kubernetes/secrets/apps/` | Application secrets |

The **SOPS Secrets Operator** watches for `SopsSecret` CRs and automatically creates decrypted `Secret` objects.

### Bootstrap Exception

The age private key (`sops-age-key`) is the only manually-deployed secret, since the operator needs it to decrypt everything else. Deployed via `just deploy-age-key`.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Secrets Flow (GitOps)                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Git Repository                                                │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │  kubernetes/secrets/infra/home-root-ca.yaml             │  │
│   │  kubernetes/secrets/apps/*.yaml                         │  │
│   │  (SopsSecret CRs with encrypted stringData)             │  │
│   └──────────────────────┬──────────────────────────────────┘  │
│                          │                                      │
│                          │ git push                             │
│                          ▼                                      │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │  ArgoCD (infra-secrets / apps-secrets)                  │  │
│   │  Syncs SopsSecret CRs to cluster                        │  │
│   └──────────────────────┬──────────────────────────────────┘  │
│                          │                                      │
│                          ▼                                      │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │  sops-secrets-operator                                  │  │
│   │  Watches SopsSecrets → Decrypts → Creates Secrets       │  │
│   │  Uses: sops-age-key secret                              │  │
│   └──────────────────────┬──────────────────────────────────┘  │
│                          │                                      │
│                          ▼                                      │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │  Kubernetes Secret (decrypted, usable by pods)          │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Setup

### 1. Generate age Key

```bash
# Generate new key
age-keygen -o ~/.config/sops/age/keys.txt

# View public key
age-keygen -y ~/.config/sops/age/keys.txt
# Output: age1abc123...
```

### 2. Configure SOPS

Each directory with secrets has a `.sops.yaml`:

```yaml
# kubernetes/.sops.yaml
creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: age1abc123...  # Your public key
```

```yaml
# talos/.sops.yaml
creation_rules:
  - path_regex: .*\.sops\.yaml$
    age: age1abc123...
```

### 3. Set Environment Variable

```bash
# In .envrc or shell profile
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

## Encrypting Secrets

### Create a SopsSecret

SopsSecrets should be encrypted with `--encrypted-regex '^stringData'` to keep the CR structure visible for ArgoCD:

```bash
# 1. Create plain SopsSecret YAML
cat > kubernetes/secrets/infra/my-secret.yaml << 'EOF'
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-secret
  namespace: default
spec:
  secretTemplates:
    - name: my-secret
      stringData:
        password: super-secret-password
EOF

# 2. Encrypt in-place (only stringData values are encrypted)
cd kubernetes
sops --encrypt --encrypted-regex '^stringData' -i secrets/infra/my-secret.yaml
```

### What Gets Encrypted

With `--encrypted-regex '^stringData'`, only the values inside `stringData` are encrypted:

```yaml
# After encryption - CR structure remains visible
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-secret
  namespace: default
spec:
  secretTemplates:
    - name: my-secret
      stringData:
        password: ENC[AES256_GCM,data:abc123...,type:str]
sops:
  # ... sops metadata
```

This allows ArgoCD to parse the YAML and sync it, while the operator decrypts the values.

## Decrypting Secrets

### View Decrypted Content

```bash
cd kubernetes
sops -d secrets/my-secret.yaml
```

### Edit Encrypted File

```bash
cd kubernetes
sops secrets/my-secret.yaml  # Opens in $EDITOR, auto-encrypts on save
```

### Deploy to Cluster

```bash
# Decrypt and apply
cd kubernetes
sops -d secrets/my-secret.yaml | kubectl apply -f -

# Or use justfile
just deploy-secrets
```

## Current Secrets

### Infrastructure Secrets (`kubernetes/secrets/infra/`)

| File | Purpose | Namespace |
|------|---------|-----------|
| `home-root-ca.yaml` | Root CA for internal TLS | cert-manager |

### Application Secrets (`kubernetes/secrets/apps/`)

Application-specific secrets go here.

### Talos Secrets

| File | Purpose |
|------|---------|
| `talos/talsecret.sops.yaml` | Talos cluster secrets (certs, keys) |

## Root CA Secret

The root CA is stored as a SopsSecret:

```yaml
# Encrypted SopsSecret structure
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: home-root-ca
  namespace: cert-manager
spec:
  secretTemplates:
    - name: home-root-ca
      type: kubernetes.io/tls
      stringData:
        tls.crt: ENC[AES256_GCM,data:...,type:str]
        tls.key: ENC[AES256_GCM,data:...,type:str]
```

The operator creates the actual `kubernetes.io/tls` Secret from this.

### Why Encrypt the Root CA?

When the cluster is rebuilt:
1. ArgoCD syncs the SopsSecret automatically
2. The operator creates the same root CA Secret
3. Existing certificates remain valid
4. Devices don't need to re-import the CA
5. No certificate warnings

### Extracting Root CA (for backup)

```bash
# Decrypt and extract from SopsSecret
cd kubernetes
sops -d secrets/infra/home-root-ca.yaml | \
  yq '.spec.secretTemplates[0].stringData["tls.crt"]' > root-ca.crt
sops -d secrets/infra/home-root-ca.yaml | \
  yq '.spec.secretTemplates[0].stringData["tls.key"]' > root-ca.key
```

### Importing Root CA to Devices

The certificate (not the key!) can be imported to trust the cluster:

```bash
# Extract just the cert
cd kubernetes
sops -d secrets/infra/home-root-ca.yaml | \
  yq '.spec.secretTemplates[0].stringData["tls.crt"]' > home-root-ca.crt

# Then import to your device/browser
```

## Talos Secrets

Generated by talhelper:

```bash
# Generate new secrets
cd talos
talhelper gensecret > talsecret.sops.yaml
sops -e -i talsecret.sops.yaml

# Decrypt for use
sops -d talsecret.sops.yaml > talsecret.yaml  # gitignored
```

Contains:
- Cluster CA certificate and key
- etcd CA certificate and key
- Kubernetes secrets
- Machine tokens

## Best Practices

### 1. Never Commit Unencrypted Secrets

```gitignore
# .gitignore
*.decrypted.yaml
talsecret.yaml
```

### 2. Verify Encryption Before Commit

```bash
# Check if file is encrypted
head -5 kubernetes/secrets/my-secret.yaml
# Should see "sops:" metadata
```

### 3. Use Multiple Keys

For team access, add multiple age keys:

```yaml
# .sops.yaml
creation_rules:
  - path_regex: .*
    age: >-
      age1user1...,
      age1user2...,
      age1user3...
```

### 4. Backup Your Key

```bash
# Backup the age key securely
cp ~/.config/sops/age/keys.txt /secure/backup/location/
```

Without the key, encrypted secrets cannot be decrypted.

## Troubleshooting

### "age: no identity matched"

Your key doesn't match the encrypted file:

```bash
# Check which keys can decrypt
sops -d kubernetes/secrets/my-secret.yaml 2>&1 | grep age
```

Re-encrypt with your key:
```bash
sops updatekeys kubernetes/secrets/my-secret.yaml
```

### "could not find .sops.yaml"

Run sops from the directory containing `.sops.yaml`:

```bash
cd kubernetes
sops -d secrets/my-secret.yaml
```

### direnv Not Loading

```bash
# Allow direnv
direnv allow

# Or manually source
source .envrc
```

## SOPS Secrets Operator

The operator enables full GitOps for secrets - no ArgoCD plugins needed.

### How It Works

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   SopsSecret     │────►│    Operator      │────►│     Secret       │
│   (encrypted)    │     │   (decrypts)     │     │   (decrypted)    │
│                  │     │                  │     │                  │
│ Committed to Git │     │ Uses age key     │     │ Used by pods     │
└──────────────────┘     └──────────────────┘     └──────────────────┘
```

### Creating a SopsSecret

```bash
# 1. Create the manifest
cat > kubernetes/secrets/apps/my-app.yaml << 'EOF'
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-app-secrets
  namespace: my-app
spec:
  secretTemplates:
    - name: my-app-credentials
      stringData:
        username: admin
        password: super-secret
EOF

# 2. Encrypt with sops (only stringData values)
cd kubernetes
sops --encrypt --encrypted-regex '^stringData' -i secrets/apps/my-app.yaml

# 3. Commit and push - ArgoCD syncs automatically
git add secrets/apps/my-app.yaml
git commit -m "feat: add my-app secrets"
git push
```

### SopsSecret Schema

```yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-secrets
  namespace: target-namespace
spec:
  # Suspend reconciliation (optional)
  suspend: false

  # Multiple secrets from one SopsSecret
  secretTemplates:
    - name: secret-one
      labels:
        app: my-app
      annotations:
        description: "My secret"
      stringData:
        key1: value1
        key2: value2

    - name: secret-two
      type: kubernetes.io/tls
      stringData:
        tls.crt: |
          -----BEGIN CERTIFICATE-----
          ...
          -----END CERTIFICATE-----
        tls.key: |
          -----BEGIN EC PRIVATE KEY-----
          ...
          -----END EC PRIVATE KEY-----
```

**Note**: Use `stringData` (not `data`) for SopsSecrets - the operator handles encoding.

### Viewing Created Secrets

```bash
# Check SopsSecret status
kubectl get sopssecrets -A

# View created secret
kubectl -n my-app get secret my-app-credentials -o yaml
```

### Age Key Bootstrap

The operator needs the age private key to decrypt secrets. This is a chicken-and-egg situation - we can't encrypt the age key with SOPS.

```bash
# Deploy age key (run once during cluster bootstrap)
just deploy-age-key
```

This creates a secret in the `sops-secrets-operator` namespace:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-age-key
  namespace: sops-secrets-operator
stringData:
  keys.txt: |
    # created: 2024-01-01T00:00:00Z
    # public key: age1abc123...
    AGE-SECRET-KEY-1ABCDEF...
```

### Migration from Manual Secrets

To convert existing manually-deployed secrets to SopsSecrets:

```bash
# 1. Export existing secret
kubectl -n cert-manager get secret home-root-ca -o yaml > temp.yaml

# 2. Convert to SopsSecret format (use stringData, not data)
cat > kubernetes/secrets/infra/home-root-ca.yaml << 'EOF'
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: home-root-ca
  namespace: cert-manager
spec:
  secretTemplates:
    - name: home-root-ca
      type: kubernetes.io/tls
      stringData:
        tls.crt: |
          <paste decoded cert>
        tls.key: |
          <paste decoded key>
EOF

# 3. Encrypt (only stringData values)
cd kubernetes
sops --encrypt --encrypted-regex '^stringData' -i secrets/infra/home-root-ca.yaml

# 4. Commit - ArgoCD syncs automatically
git add secrets/infra/home-root-ca.yaml
git commit -m "refactor: migrate home-root-ca to SopsSecret"
git push
```

## Bootstrap vs GitOps Secrets

| Secret | Type | Why |
|--------|------|-----|
| `sops-age-key` | Manual (`just deploy-age-key`) | Can't encrypt the decryption key |
| `home-root-ca` | SopsSecret (infra-secrets) | GitOps managed |
| App credentials | SopsSecret (apps-secrets) | GitOps managed |
