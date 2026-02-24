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
k8s_infra := "kubernetes/infra"

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

# Install all K8s infrastructure: Cilium, storage (local-path + Kadalu), ArgoCD
install: install-cilium install-local-path install-kadalu install-argocd
    @echo ""
    @echo "══════════════════════════════════════════════════════════"
    @echo "  ✓ Kubernetes infrastructure installed!"
    @echo ""
    @echo "  CNI: Cilium with L2 announcements"
    @echo "  Storage: local-path (NVMe) + kadalu.replica2 (external drives)"
    @echo "  GitOps: ArgoCD"
    @echo ""
    @echo "══════════════════════════════════════════════════════════"

# Uninstall all K8s infrastructure (reverse order)
uninstall: uninstall-argocd uninstall-kadalu uninstall-local-path uninstall-cilium
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
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --values {{k8s_infra}}/cilium/values.yaml \
        --wait --timeout 5m
    echo "✓ Cilium installed"
    echo "   Waiting for Cilium pods..."
    kubectl -n kube-system rollout status ds/cilium --timeout=3m
    kubectl apply -f {{k8s_infra}}/cilium/lb-pool.yaml
    echo "✓ Cilium L2 pool configured"

# Uninstall Cilium (WARNING: breaks networking!)
uninstall-cilium:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Uninstalling Cilium..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl delete -f {{k8s_infra}}/cilium/lb-pool.yaml 2>/dev/null || true
    helm uninstall cilium -n kube-system 2>/dev/null || true
    echo "✓ Cilium uninstalled"

# ── Local Path Provisioner ────────────────────────────────────────────────────

# Install Local Path Provisioner (node-local NVMe storage)
install-local-path:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Installing Local Path Provisioner..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl apply -f {{k8s_infra}}/local-path/manifest.yaml
    echo "   Waiting for provisioner pod..."
    kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=2m
    echo "✓ Local Path Provisioner installed"

# Uninstall Local Path Provisioner
uninstall-local-path:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Uninstalling Local Path Provisioner..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl delete -f {{k8s_infra}}/local-path/manifest.yaml 2>/dev/null || true
    echo "✓ Local Path Provisioner uninstalled"

# ── Kadalu (GlusterFS) ────────────────────────────────────────────────────────

# Install Kadalu operator and storage
install-kadalu:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Installing Kadalu..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    # Create namespace with privileged PodSecurity
    kubectl apply -f {{k8s_infra}}/kadalu/namespace.yaml
    # Install Kadalu operator via Helm (direct from GitHub release)
    helm upgrade --install kadalu \
        https://github.com/kadalu/kadalu/releases/latest/download/kadalu-helm-chart.tgz \
        --namespace kadalu \
        --set operator.enabled=true \
        --set global.kubernetesDistro=kubernetes \
        --wait --timeout 5m
    echo "✓ Kadalu operator installed"
    echo "   Waiting for operator to be ready..."
    kubectl -n kadalu rollout status deployment/operator --timeout=2m
    echo "   Waiting for CSI provisioner..."
    kubectl -n kadalu rollout status statefulset/kadalu-csi-provisioner --timeout=3m
    # Create storage pool (Replica2 with tiebreaker)
    echo "   Creating Replica2 storage pool..."
    kubectl apply -f {{k8s_infra}}/kadalu/storage.yaml
    # Apply StorageClass with default annotation
    kubectl apply -f {{k8s_infra}}/kadalu/storageclass.yaml
    echo "✓ Kadalu storage configured (default StorageClass)"
    echo ""
    echo "  StorageClass: kadalu.replica2"
    echo "  Drives: node-1:/dev/sda + node-2:/dev/sda (mirrored)"
    echo "  Tiebreaker: node-3"

# Uninstall Kadalu (WARNING: deletes all PVs!)
uninstall-kadalu:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Uninstalling Kadalu..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl delete -f {{k8s_infra}}/kadalu/storage.yaml 2>/dev/null || true
    helm uninstall kadalu -n kadalu 2>/dev/null || true
    kubectl delete namespace kadalu --timeout=5m 2>/dev/null || true
    echo "✓ Kadalu uninstalled"

# ── ArgoCD ────────────────────────────────────────────────────────────────────

# Install ArgoCD
install-argocd:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Installing ArgoCD..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo update argo >/dev/null
    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace \
        --values {{k8s_infra}}/argocd/values.yaml \
        --wait --timeout 5m
    echo "✓ ArgoCD installed"
    echo ""
    echo "  Get admin password:"
    echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

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

# Bootstrap ArgoCD App of Apps (after install-argocd)
argocd-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "══ Bootstrapping ArgoCD App of Apps..."
    export KUBECONFIG={{cluster_dir}}/kubeconfig
    kubectl apply -f kubernetes/apps/root.yaml
    echo "✓ ArgoCD root application created"
    echo "   ArgoCD will now sync all apps from kubernetes/apps/"

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
