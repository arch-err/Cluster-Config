#!/usr/bin/env bash
set -euo pipefail

readonly PUBLIC_TEST_NAMESPACE="public-edge-verification"
readonly REJECTION_TEST_NAMESPACE="public-route-rejection-test"
readonly PUBLIC_TEST_HOST="edge-verify.3rr.dev"
readonly PROBE_IMAGE="curlimages/curl:8.10.1"
readonly BACKEND_IMAGE="ghcr.io/stefanprodan/podinfo:6.9.2@sha256:2ff7e09117596b13739e85bde01c8a33d56265013518910ab681df0fbea13b54"

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

expect_server_dry_run_denied() {
  local description=$1 expected_message=$2
  local stderr_file
  stderr_file=$(mktemp)
  if kubectl apply --dry-run=server -f - >/dev/null 2>"$stderr_file"; then
    rm -f "$stderr_file"
    fail "$description was unexpectedly admitted"
  fi
  if rg -q "$expected_message" "$stderr_file"; then
    rm -f "$stderr_file"
    pass "$description is rejected by admission"
    return
  fi
  sed -n '1,12p' "$stderr_file" >&2
  rm -f "$stderr_file"
  fail "$description did not fail with the expected admission message"
}

cleanup() {
  kubectl -n cloudflare-tunnel delete pod tunnel-egress-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "$PUBLIC_TEST_NAMESPACE" "$REJECTION_TEST_NAMESPACE" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

for namespace in "$PUBLIC_TEST_NAMESPACE" "$REJECTION_TEST_NAMESPACE"; do
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    kubectl delete namespace "$namespace" --wait=true --timeout=90s >/dev/null \
      || fail "stale verification namespace $namespace could not be removed"
  fi
done

kubectl -n gateway-system wait --for=condition=Programmed gateway/public --timeout=2m >/dev/null \
  && pass "public Gateway is programmed" \
  || fail "public Gateway is not programmed"

service_json=$(kubectl -n gateway-system get service cilium-gateway-public -o json)
jq -e '.spec.type == "LoadBalancer" and .spec.allocateLoadBalancerNodePorts == false and
  ([.spec.ports[].nodePort // empty] | length == 0) and
  .spec.loadBalancerSourceRanges == ["10.244.0.0/16"]' >/dev/null <<<"$service_json" \
  && pass "public Gateway has no NodePort and only accepts Pod CIDRs on its LB address" \
  || fail "public Gateway Service exposure does not match the hardened shape"

kubectl create namespace "$PUBLIC_TEST_NAMESPACE" >/dev/null
kubectl label namespace "$PUBLIC_TEST_NAMESPACE" \
  exposure=public \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted >/dev/null
kubectl -n "$PUBLIC_TEST_NAMESPACE" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: public-backend
  labels:
    app.kubernetes.io/name: public-backend
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: ${BACKEND_IMAGE}
      ports:
        - name: http
          containerPort: 9898
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 128Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
---
apiVersion: v1
kind: Service
metadata:
  name: public-backend
spec:
  selector:
    app.kubernetes.io/name: public-backend
  ports:
    - name: http
      port: 80
      targetPort: 9898
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: public-backend
spec:
  parentRefs:
    - name: public
      namespace: gateway-system
  hostnames:
    - ${PUBLIC_TEST_HOST}
  rules:
    - backendRefs:
        - name: public-backend
          port: 80
YAML
kubectl -n "$PUBLIC_TEST_NAMESPACE" wait --for=condition=Ready pod/public-backend --timeout=90s >/dev/null

[[ $(kubectl get namespace "$PUBLIC_TEST_NAMESPACE" -o jsonpath='{.metadata.labels.exposure}') == public ]] \
  && pass "ephemeral namespace carries the public exposure label" \
  || fail "ephemeral namespace is not labelled public"
[[ $(kubectl get namespace "$PUBLIC_TEST_NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') == restricted ]] \
  && pass "ephemeral namespace enforces restricted Pod Security" \
  || fail "ephemeral namespace does not enforce restricted Pod Security"

for _ in {1..30}; do
  if kubectl -n "$PUBLIC_TEST_NAMESPACE" get httproute public-backend -o json 2>/dev/null | jq -e \
    '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "True")] | length > 0' >/dev/null; then
    pass "ephemeral public HTTPRoute is accepted"
    break
  fi
  sleep 1
done
kubectl -n "$PUBLIC_TEST_NAMESPACE" get httproute public-backend -o json | jq -e \
  '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "True")] | length > 0' >/dev/null \
  || fail "ephemeral public HTTPRoute is not accepted"

kubectl create namespace "$REJECTION_TEST_NAMESPACE" >/dev/null
kubectl -n "$REJECTION_TEST_NAMESPACE" apply -f - >/dev/null <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: rejected
spec:
  parentRefs:
    - name: public
      namespace: gateway-system
  hostnames:
    - rejected.3rr.dev
  rules:
    - backendRefs:
        - name: nonexistent
          port: 80
YAML
for _ in {1..30}; do
  if kubectl -n "$REJECTION_TEST_NAMESPACE" get httproute rejected -o json 2>/dev/null | jq -e \
    '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "False" and .reason == "NotAllowedByListeners")] | length > 0' >/dev/null; then
    pass "unlabelled namespace cannot attach a route to the public Gateway"
    break
  fi
  sleep 1
done
kubectl -n "$REJECTION_TEST_NAMESPACE" get httproute rejected -o json | jq -e \
  '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "False" and .reason == "NotAllowedByListeners")] | length > 0' >/dev/null \
  || fail "unlabelled route was not explicitly rejected"

expect_server_dry_run_denied "selectorless public Service" "Public namespaces may only expose selector-backed Services" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: selectorless-deny-probe
  namespace: public-edge-verification
spec:
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

expect_server_dry_run_denied "ExternalName public Service" "Public namespaces may only expose selector-backed Services" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: externalname-deny-probe
  namespace: public-edge-verification
spec:
  type: ExternalName
  externalName: pocket-id.pocket-id.svc.cluster.local
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

expect_server_dry_run_denied "manual public EndpointSlice" "Public namespace EndpointSlices must be managed by the Kubernetes endpoint-slice controller" <<'YAML'
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: endpointslice-deny-probe
  namespace: public-edge-verification
  labels:
    kubernetes.io/service-name: public-backend
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 80
endpoints:
  - addresses:
      - 10.244.2.99
    conditions:
      ready: true
YAML

kubectl create --dry-run=server \
  --as=system:serviceaccount:kube-system:endpointslice-controller \
  -f - >/dev/null <<'YAML' \
  && pass "EndpointSlice controller can manage public backends" \
  || fail "EndpointSlice controller is blocked from managing public backends"
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: endpointslice-controller-allow-probe
  namespace: public-edge-verification
  labels:
    kubernetes.io/service-name: public-backend
    endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io
addressType: IPv4
ports:
  - name: http
    protocol: TCP
    port: 9898
endpoints: []
YAML

run_probe() {
  local namespace=$1 name=$2
  local overrides
  overrides=$(jq -nc '{spec:{automountServiceAccountToken:false,enableServiceLinks:false,securityContext:{runAsNonRoot:true,runAsUser:100,runAsGroup:100,seccompProfile:{type:"RuntimeDefault"}},containers:[{name:"probe",image:"curlimages/curl:8.10.1",command:["sleep","600"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}')
  kubectl -n "$namespace" run "$name" --restart=Never --image="$PROBE_IMAGE" --overrides="$overrides" --command -- sleep 600 >/dev/null
  kubectl -n "$namespace" wait --for=condition=Ready "pod/$name" --timeout=90s >/dev/null
}

run_probe "$PUBLIC_TEST_NAMESPACE" public-egress-probe
kubectl -n "$PUBLIC_TEST_NAMESPACE" exec public-egress-probe -- curl -4fsS --connect-timeout 5 --max-time 15 https://example.com >/dev/null \
  && pass "public namespace retains HTTPS Internet egress" \
  || fail "public namespace cannot reach the Internet over HTTPS"

for target in \
  http://pocket-id.pocket-id.svc.cluster.local \
  https://kubernetes.default.svc \
  https://10.10.10.171:50000 \
  http://10.10.10.1 \
  http://10.20.20.1; do
  if kubectl -n "$PUBLIC_TEST_NAMESPACE" exec public-egress-probe -- \
    curl -ksS --connect-timeout 2 --max-time 4 -o /dev/null "$target" >/dev/null 2>&1; then
    fail "public namespace unexpectedly reached protected target $target"
  fi
  pass "public namespace cannot reach protected target $target"
done

run_probe cloudflare-tunnel tunnel-egress-probe
kubectl -n cloudflare-tunnel exec tunnel-egress-probe -- \
  curl -fsS --connect-timeout 3 --max-time 10 -H "Host: $PUBLIC_TEST_HOST" \
  http://cilium-gateway-public.gateway-system.svc.cluster.local/readyz >/dev/null \
  && pass "tunnel namespace can reach the public Gateway and selected backend" \
  || fail "tunnel namespace cannot reach the public Gateway"
if kubectl -n cloudflare-tunnel exec tunnel-egress-probe -- \
  curl -sS --connect-timeout 2 --max-time 4 -o /dev/null http://pocket-id.pocket-id.svc.cluster.local >/dev/null 2>&1; then
  fail "tunnel namespace unexpectedly reached an internal service"
fi
pass "tunnel namespace cannot reach internal services"

kubectl -n cloudflare-tunnel rollout status deployment/cloudflared --timeout=2m >/dev/null \
  && pass "cloudflared connector is ready" \
  || fail "cloudflared connector is not ready"

echo "All public-edge isolation checks passed."
