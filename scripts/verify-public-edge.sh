#!/usr/bin/env bash
set -euo pipefail

readonly TEST_NAMESPACE="public-route-rejection-test"
readonly PROBE_IMAGE="curlimages/curl:8.10.1"

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
  kubectl -n public-test delete pod public-egress-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n cloudflare-tunnel delete pod tunnel-egress-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n gateway-system wait --for=condition=Programmed gateway/public --timeout=2m >/dev/null \
  && pass "public Gateway is programmed" \
  || fail "public Gateway is not programmed"

service_json=$(kubectl -n gateway-system get service cilium-gateway-public -o json)
jq -e '.spec.type == "LoadBalancer" and .spec.allocateLoadBalancerNodePorts == false and
  ([.spec.ports[].nodePort // empty] | length == 0) and
  .spec.loadBalancerSourceRanges == ["10.244.0.0/16"]' >/dev/null <<<"$service_json" \
  && pass "public Gateway has no NodePort and only accepts Pod CIDRs on its LB address" \
  || fail "public Gateway Service exposure does not match the hardened shape"

[[ $(kubectl get namespace public-test -o jsonpath='{.metadata.labels.exposure}') == public ]] \
  && pass "public-test namespace carries the public exposure label" \
  || fail "public-test namespace is not labelled public"
[[ $(kubectl get namespace public-test -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') == restricted ]] \
  && pass "public-test namespace enforces restricted Pod Security" \
  || fail "public-test namespace does not enforce restricted Pod Security"

kubectl -n public-test get httproute public-test -o json | jq -e \
  '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "True")] | length > 0' >/dev/null \
  && pass "public test HTTPRoute is accepted" \
  || fail "public test HTTPRoute is not accepted"

kubectl create namespace "$TEST_NAMESPACE" >/dev/null
kubectl -n "$TEST_NAMESPACE" apply -f - >/dev/null <<'YAML'
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
  if kubectl -n "$TEST_NAMESPACE" get httproute rejected -o json 2>/dev/null | jq -e \
    '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "False" and .reason == "NotAllowedByListeners")] | length > 0' >/dev/null; then
    pass "unlabelled namespace cannot attach a route to the public Gateway"
    break
  fi
  sleep 1
done
kubectl -n "$TEST_NAMESPACE" get httproute rejected -o json | jq -e \
  '[.status.parents[].conditions[] | select(.type == "Accepted" and .status == "False" and .reason == "NotAllowedByListeners")] | length > 0' >/dev/null \
  || fail "unlabelled route was not explicitly rejected"

expect_server_dry_run_denied "selectorless public Service" "Public namespaces may only expose selector-backed Services" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: selectorless-deny-probe
  namespace: public-test
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
  namespace: public-test
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
  namespace: public-test
  labels:
    kubernetes.io/service-name: public-test
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

run_probe() {
  local namespace=$1 name=$2
  local overrides
  overrides=$(jq -nc '{spec:{automountServiceAccountToken:false,enableServiceLinks:false,securityContext:{runAsNonRoot:true,runAsUser:100,runAsGroup:100,seccompProfile:{type:"RuntimeDefault"}},containers:[{name:"probe",image:"curlimages/curl:8.10.1",command:["sleep","600"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}')
  kubectl -n "$namespace" run "$name" --restart=Never --image="$PROBE_IMAGE" --overrides="$overrides" --command -- sleep 600 >/dev/null
  kubectl -n "$namespace" wait --for=condition=Ready "pod/$name" --timeout=90s >/dev/null
}

run_probe public-test public-egress-probe
kubectl -n public-test exec public-egress-probe -- curl -4fsS --connect-timeout 5 --max-time 15 https://example.com >/dev/null \
  && pass "public namespace retains HTTPS Internet egress" \
  || fail "public namespace cannot reach the Internet over HTTPS"

for target in \
  http://pocket-id.pocket-id.svc.cluster.local \
  https://kubernetes.default.svc \
  https://10.10.10.171:50000 \
  http://10.10.10.1 \
  http://10.20.20.1; do
  if kubectl -n public-test exec public-egress-probe -- \
    curl -ksS --connect-timeout 2 --max-time 4 -o /dev/null "$target" >/dev/null 2>&1; then
    fail "public namespace unexpectedly reached protected target $target"
  fi
  pass "public namespace cannot reach protected target $target"
done

run_probe cloudflare-tunnel tunnel-egress-probe
kubectl -n cloudflare-tunnel exec tunnel-egress-probe -- \
  curl -fsS --connect-timeout 3 --max-time 10 -H 'Host: edge-test.3rr.dev' \
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
