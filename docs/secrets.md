# Secrets Management

Secrets are encrypted using [SOPS](https://github.com/mozilla/sops) with [age](https://github.com/FiloSottile/age) encryption.

## Two Approaches

| Approach | Use Case |
|----------|----------|
| **SopsSecret CRD** | GitOps-managed secrets (preferred) |
| **Manual deploy** | Bootstrap secrets (age key, root CA) |

The **SOPS Secrets Operator** watches for `SopsSecret` custom resources and automatically creates decrypted `Secret` objects. This is the preferred approach for application secrets.

Bootstrap secrets (like the age key itself) must be deployed manually since they're needed before the operator can function.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Secrets Flow                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Developer Workstation                                         │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                                                          │  │
│   │  age private key (~/.config/sops/age/keys.txt)          │  │
│   │           │                                              │  │
│   │           ▼                                              │  │
│   │  sops -d secret.yaml  ──►  Decrypted YAML               │  │
│   │                                                          │  │
│   └─────────────────────────────────────────────────────────┘  │
│                           │                                     │
│                           │ kubectl apply                       │
│                           ▼                                     │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                    Kubernetes                            │  │
│   │                                                          │  │
│   │  Secret object (decrypted, stored in etcd)              │  │
│   │                                                          │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
│   Git Repository                                                │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                                                          │  │
│   │  kubernetes/secrets/home-root-ca.yaml  (SOPS encrypted) │  │
│   │  talos/talsecret.sops.yaml             (SOPS encrypted) │  │
│   │                                                          │  │
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

### Create a New Secret

```bash
# Create plain YAML
cat > kubernetes/secrets/my-secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: default
type: Opaque
stringData:
  password: super-secret-password
EOF

# Encrypt in-place
cd kubernetes
sops -e -i secrets/my-secret.yaml
```

### Encrypt Specific Fields

SOPS encrypts only the values, not the keys:

```yaml
# Before encryption
stringData:
  password: super-secret-password

# After encryption
stringData:
  password: ENC[AES256_GCM,data:abc123...,type:str]
```

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

### Kubernetes Secrets

| File | Purpose | Namespace |
|------|---------|-----------|
| `kubernetes/secrets/home-root-ca.yaml` | Root CA for internal TLS | cert-manager |

### Talos Secrets

| File | Purpose |
|------|---------|
| `talos/talsecret.sops.yaml` | Talos cluster secrets (certs, keys) |

## Root CA Secret

The root CA is crucial for TLS:

```yaml
# Decrypted structure
apiVersion: v1
kind: Secret
metadata:
  name: home-root-ca
  namespace: cert-manager
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-cert>
  tls.key: <base64-encoded-key>
```

### Why Encrypt the Root CA?

When the cluster is rebuilt:
1. The same root CA is deployed
2. Existing certificates remain valid
3. Devices don't need to re-import the CA
4. No certificate warnings

### Extracting Root CA (for backup)

```bash
cd kubernetes
sops -d secrets/home-root-ca.yaml | \
  yq '.data["tls.crt"]' | base64 -d > root-ca.crt
sops -d secrets/home-root-ca.yaml | \
  yq '.data["tls.key"]' | base64 -d > root-ca.key
```

### Importing Root CA to Devices

The certificate (not the key!) can be imported to trust the cluster:

```bash
# Extract just the cert
sops -d kubernetes/secrets/home-root-ca.yaml | \
  yq '.data["tls.crt"]' | base64 -d > home-root-ca.crt

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
cat > kubernetes/secrets/my-app.yaml << 'EOF'
apiVersion: isindir.github.io/v1alpha3
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

# 2. Encrypt with sops
cd kubernetes
sops -e -i secrets/my-app.yaml

# 3. Commit and push
git add secrets/my-app.yaml
git commit -m "feat: add my-app secrets"
git push
```

### SopsSecret Schema

```yaml
apiVersion: isindir.github.io/v1alpha3
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
      data:
        tls.crt: <base64>
        tls.key: <base64>
```

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

# 2. Convert to SopsSecret format
cat > kubernetes/secrets/home-root-ca.yaml << 'EOF'
apiVersion: isindir.github.io/v1alpha3
kind: SopsSecret
metadata:
  name: home-root-ca
  namespace: cert-manager
spec:
  secretTemplates:
    - name: home-root-ca
      type: kubernetes.io/tls
      data:
        tls.crt: <paste from temp.yaml>
        tls.key: <paste from temp.yaml>
EOF

# 3. Encrypt
cd kubernetes && sops -e -i secrets/home-root-ca.yaml

# 4. Commit
git add secrets/home-root-ca.yaml
git commit -m "refactor: migrate home-root-ca to SopsSecret"
```

## Bootstrap vs GitOps Secrets

| Secret | Type | Why |
|--------|------|-----|
| `sops-age-key` | Manual | Can't encrypt the decryption key |
| `home-root-ca` | SopsSecret | Normal secret, GitOps managed |
| App credentials | SopsSecret | Normal secret, GitOps managed |
