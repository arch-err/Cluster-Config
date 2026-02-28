# Cluster bootstrap justfile
# Two layers:
#   - Talos layer: 'just bootstrap' - PXE boot, apply configs, bootstrap etcd
#   - K8s layer: 'just install' - Cilium, storage, ArgoCD

set shell := ["bash", "-uc"]

# Talos version
talos_version := "v1.12.4"

# Node configuration
node1 := "192.168.1.71"
node2 := "192.168.1.72"
node3 := "192.168.1.73"
vip := "192.168.1.70"

# MAC addresses (for PXE boot monitoring)
mac1 := "10:e7:c6:0d:12:be"
mac2 := "10:e7:c6:0d:12:62"
mac3 := "10:e7:c6:0d:61:18"

# Network interface for PXE/booter (must be wired - WiFi doesn't work for DHCP proxy)
booter_interface := "enp0s20f0u2u1u2"

# Paths
talos_dir := "talos"
cluster_dir := talos_dir / "clusterconfig"
talosconfig := cluster_dir / "talosconfig"

# Default recipe
default:
    @just --list

# ══════════════════════════════════════════════════════════════════════════════
# TALOS LAYER
# ══════════════════════════════════════════════════════════════════════════════

# Full Talos bootstrap: wipe nodes, PXE boot, apply configs, bootstrap etcd
bootstrap: generate booter-wipe _apply-all-nodes _booter-stop _bootstrap-cluster _get-kubeconfig _wait-for-k8s
    @echo ""
    @echo "══════════════════════════════════════════════════════════"
    @echo "  ✓ Talos bootstrap complete!"
    @echo ""
    @echo "  Cluster: 3 control-plane nodes"
    @echo "  VIP: {{vip}}"
    @echo ""
    @echo "  Next step: run 'just install' to install Cilium + storage + ArgoCD"
    @echo ""
    @echo "  Export kubeconfig:"
    @echo "    export KUBECONFIG=$(pwd)/{{cluster_dir}}/kubeconfig"
    @echo ""
    @echo "══════════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════════════════════════
# KUBERNETES LAYER
# ══════════════════════════════════════════════════════════════════════════════

# Install K8s infrastructure: Cilium + ArgoCD + age key (ArgoCD manages the rest via GitOps)
install: install-cilium install-argocd deploy-age-key
    @echo ""
    @echo "══════════════════════════════════════════════════════════"
    @echo "  ✓ Kubernetes infrastructure installed!"
    @echo ""
    @echo "  CNI: Cilium with Gateway API + L2 announcements"
    @echo "  GitOps: ArgoCD (managing infra + apps via GitOps)"
    @echo ""
    @echo "  ArgoCD will now sync all infrastructure from Git:"
    @echo "    - sops-secrets-operator (decrypts SopsSecrets)"
    @echo "    - infra-secrets (root CA, etc.)"
    @echo "    - cert-manager, gateways, certificates"
    @echo "    - kadalu storage"
    @echo "    - user applications"
    @echo ""
    @echo "══════════════════════════════════════════════════════════"

# Uninstall all K8s infrastructure (reverse order)
uninstall: uninstall-argocd uninstall-cilium
    @echo ""
    @echo "══════════════════════════════════════════════════════════"
    @echo "  ✓ Kubernetes infrastructure uninstalled"
    @echo "══════════════════════════════════════════════════════════"

# Reinstall all K8s infrastructure
reinstall: uninstall install

# ── Cilium ────────────────────────────────────────────────────────────────────

# Install Cilium CNI
install-cilium:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Installing Cilium..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update cilium >/dev/null
    # Install experimental Gateway API CRDs (TLSRoute, etc. required by Cilium)
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml 2>/dev/null || true
    # Execute the values file directly (shebang has helm install args)
    kubernetes/bootstrap/cilium.yaml --wait --timeout 5m
    echo "✓ Cilium installed"
    echo "   Waiting for Cilium pods..."
    kubectl -n kube-system rollout status ds/cilium --timeout=3m
    echo "✓ Cilium ready"

# Uninstall Cilium (WARNING: breaks networking!)
uninstall-cilium:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Uninstalling Cilium..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    helm uninstall cilium -n kube-system 2>/dev/null || true
    echo "✓ Cilium uninstalled"

# ── ArgoCD ────────────────────────────────────────────────────────────────────

# Install ArgoCD (includes root apps via extraObjects)
install-argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Installing ArgoCD..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update argo >/dev/null
    # Execute the values file directly (shebang has helm install args + extraObjects)
    kubernetes/bootstrap/argocd.yaml --wait --timeout 5m
    echo "✓ ArgoCD installed with root applications"
    echo ""
    echo "  ArgoCD will sync:"
    echo "    - infra: platform chart with infra.yaml values"
    echo "    - apps: platform chart with apps.yaml values"
    echo ""
    echo "  Get admin password:"
    echo "    just argocd-password"

# Uninstall ArgoCD
uninstall-argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Uninstalling ArgoCD..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    # Delete all ArgoCD Applications first (so they don't block)
    kubectl delete applications -n argocd --all 2>/dev/null || true
    helm uninstall argocd -n argocd 2>/dev/null || true
    kubectl delete namespace argocd --timeout=2m 2>/dev/null || true
    echo "✓ ArgoCD uninstalled"

# Deploy SOPS age key (required for sops-secrets-operator)
deploy-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Deploying SOPS age key..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig

    # Find age key file
    AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
    if [[ ! -f "$AGE_KEY_FILE" ]]; then
        echo "Error: Age key not found at $AGE_KEY_FILE"
        echo "Set SOPS_AGE_KEY_FILE or create key with: age-keygen -o ~/.config/sops/age/keys.txt"
        exit 1
    fi

    # Create namespace if needed
    kubectl create namespace sops-secrets-operator 2>/dev/null || true

    # Create secret with age key
    kubectl create secret generic sops-age-key \
        --namespace sops-secrets-operator \
        --from-file=keys.txt="$AGE_KEY_FILE" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo "✓ Age key deployed to sops-secrets-operator namespace"

# [DEPRECATED] Manual secret deployment - secrets are now managed by ArgoCD via SopsSecrets
# Use this only for debugging or if you need to manually apply a secret
deploy-secrets-manual:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Manually deploying SOPS-encrypted secrets..."
    echo "   NOTE: Secrets are normally managed by ArgoCD + sops-secrets-operator"
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    source .envrc 2>/dev/null || true

    # Apply SopsSecrets from infra
    cd kubernetes
    for secret in secrets/infra/*.yaml; do
        if [ -f "$secret" ] && [ "$(basename $secret)" != ".gitkeep" ]; then
            echo "   Applying $(basename $secret)..."
            kubectl apply -f "$secret"
        fi
    done
    # Apply SopsSecrets from apps
    for secret in secrets/apps/*.yaml; do
        if [ -f "$secret" ] && [ "$(basename $secret)" != ".gitkeep" ]; then
            echo "   Applying $(basename $secret)..."
            kubectl apply -f "$secret"
        fi
    done
    echo "✓ SopsSecrets applied (operator will decrypt them)"

# Get ArgoCD admin password
argocd-password:
    #!/usr/bin/env bash
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
    echo ""

# Port-forward ArgoCD UI (localhost:8080)
argocd-ui:
    #!/usr/bin/env bash
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    echo "ArgoCD UI: https://localhost:8080"
    echo "Username: admin"
    echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
    echo ""
    kubectl port-forward svc/argocd-server -n argocd 8080:443

# ══════════════════════════════════════════════════════════════════════════════
# TALOS INDIVIDUAL STEPS
# ══════════════════════════════════════════════════════════════════════════════

# Generate Talos configs from talhelper
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Generating Talos configs..."
    source .envrc 2>/dev/null || true
    cd {{talos_dir}} && talhelper genconfig
    echo "✓ Configs generated"

# === BOOTER (PXE) ===

# Two-phase booter: wipe existing nodes, then boot clean
booter-wipe:
    @echo "══ Starting two-phase booter (wipe + clean)..."
    @./scripts/booter-wipe -i {{booter_interface}} -v {{talos_version}} {{mac1}} {{mac2}} {{mac3}}

# Stop booter
_booter-stop:
    @echo "══ Stopping PXE booter..."
    @sudo podman stop booter 2>/dev/null || true
    @echo "✓ Booter stopped"

# === NODE CONFIGURATION ===

# Wait for a node to be reachable in maintenance mode and apply config
_wait-and-apply node config:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "   Waiting for {{node}} to PXE boot..."
    # Wait for node to be reachable on port 50000 (Talos API in maintenance)
    while ! nc -z -w1 {{node}} 50000 2>/dev/null; do
        sleep 2
    done
    echo "   {{node}} is up, applying config..."
    sleep 3  # Brief pause for service to stabilize
    talosctl apply-config --insecure --nodes {{node}} --file {{config}}
    echo "   ✓ {{node}} configured"

# Apply configs to all nodes as they boot
_apply-all-nodes:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Waiting for nodes to PXE boot and applying configs..."
    echo "   (Power on nodes now if not already done)"
    echo ""
    # Apply to all nodes in parallel
    just _wait-and-apply {{node1}} {{cluster_dir}}/cluster-NODE-1.yaml &
    PID1=$!
    just _wait-and-apply {{node2}} {{cluster_dir}}/cluster-NODE-2.yaml &
    PID2=$!
    just _wait-and-apply {{node3}} {{cluster_dir}}/cluster-NODE-3.yaml &
    PID3=$!
    # Wait for all to complete
    wait $PID1 $PID2 $PID3
    echo ""
    echo "✓ All nodes configured"

# === CLUSTER BOOTSTRAP ===

_bootstrap-cluster:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Waiting for node to be reachable..."
    # Wait for node1 to respond (booting state is fine)
    echo "   Waiting for {{node1}} to be reachable..."
    timeout 120 bash -c 'until talosctl --talosconfig {{talosconfig}} -e {{node1}} -n {{node1}} get machinestatus 2>/dev/null | grep -qE "booting|running"; do sleep 5; done'
    echo "   ✓ {{node1}} reachable"

    # Bootstrap etcd on node1 (this moves it from booting to running)
    echo "══ Bootstrapping etcd on {{node1}}..."
    talosctl --talosconfig {{talosconfig}} -e {{node1}} -n {{node1}} bootstrap || true
    echo "✓ Bootstrap initiated"

    # Now wait for running state
    echo "══ Waiting for nodes to enter running state..."
    for node in {{node1}} {{node2}} {{node3}}; do
        echo "   Waiting for $node..."
        timeout 300 bash -c "until talosctl --talosconfig {{talosconfig}} -e $node -n $node get machinestatus 2>/dev/null | grep -q 'running'; do sleep 5; done"
        echo "   ✓ $node ready"
    done

_get-kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Fetching kubeconfig..."
    sleep 5
    # Retry loop for kubeconfig (cert timing issues)
    for i in {1..30}; do
        if talosctl --talosconfig {{talosconfig}} -e {{node1}} -n {{node1}} kubeconfig {{cluster_dir}}/kubeconfig --force 2>/dev/null; then
            echo "✓ Kubeconfig saved to {{cluster_dir}}/kubeconfig"
            exit 0
        fi
        sleep 5
    done
    echo "Failed to get kubeconfig"
    exit 1

_wait-for-k8s:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Waiting for Kubernetes API..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    timeout 300 bash -c 'until kubectl get nodes &>/dev/null; do sleep 5; done'
    echo "✓ Kubernetes API ready"
    echo ""
    kubectl get nodes -o wide

# === UTILITIES ===

# Show cluster status
status:
    #!/usr/bin/env bash
    echo "══ Talos Status:"
    talosctl --talosconfig {{talosconfig}} -e {{node1}} --nodes {{node1}},{{node2}},{{node3}} get machinestatus 2>/dev/null || echo "   Nodes not reachable"
    echo ""
    echo "══ Kubernetes Status:"
    export KUBECONFIG={{cluster_dir}}/kubeconfig 2>/dev/null
    kubectl get nodes -o wide 2>/dev/null || echo "   Kubernetes not ready"
    echo ""
    kubectl get pods -A 2>/dev/null | head -20 || true

# Interactive talosctl dashboard (node: 1, 2, 3, or IP)
dashboard node="1":
    #!/usr/bin/env bash
    case "{{node}}" in
        1) ip="{{node1}}" ;;
        2) ip="{{node2}}" ;;
        3) ip="{{node3}}" ;;
        *) ip="{{node}}" ;;
    esac
    talosctl --talosconfig {{talosconfig}} -e "$ip" -n "$ip" dashboard

# Talos services on a node
services node=node1:
    talosctl --talosconfig {{talosconfig}} -e {{node}} -n {{node}} services

# Kubernetes containers on a node
containers node=node1:
    talosctl --talosconfig {{talosconfig}} -e {{node}} -n {{node}} containers -k

# Approve pending kubelet CSRs
approve-csrs:
    #!/usr/bin/env bash
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    csrs=$(kubectl get csr --no-headers 2>/dev/null | grep Pending | awk '{print $1}')
    if [ -z "$csrs" ]; then
        echo "No pending CSRs"
    else
        echo "$csrs" | wc -l | xargs -I{} echo "Approving {} pending CSRs..."
        echo "$csrs" | xargs kubectl certificate approve
        echo "✓ Done"
    fi

# === MANUAL STEPS (if not using full bootstrap) ===

# Stop booter manually
booter-stop: _booter-stop

# Apply config to a single node
apply-node node config:
    talosctl apply-config --insecure --nodes {{node}} --file {{config}}

# === DESTRUCTIVE OPERATIONS ===

# Reset all nodes (DESTRUCTIVE - requires confirmation)
reset:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "⚠️  WARNING: This will WIPE ALL DATA on all cluster nodes!"
    echo "    Nodes: {{node1}}, {{node2}}, {{node3}}"
    echo ""
    read -p "Type 'RESET' to confirm: " confirm
    if [[ "$confirm" != "RESET" ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Resetting nodes..."
    for node in {{node1}} {{node2}} {{node3}}; do
        echo "  Resetting $node..."
        talosctl --talosconfig {{talosconfig}} -e $node -n $node reset --graceful=false --reboot 2>/dev/null || true
    done
    echo "✓ Reset initiated. Nodes will reboot."
