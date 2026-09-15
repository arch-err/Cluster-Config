#!/usr/bin/env bash
set -euo pipefail

readonly NAMESPACE=local-git-mux
readonly VIP=10.10.10.203
readonly HOSTNAME=git.3rr.dev
readonly PROBE=local-git-mux-untrusted-probe
readonly PROBE_IMAGE=curlimages/curl:8.10.1

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1" >&2; exit 1; }

cleanup() {
  kubectl -n default delete pod "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" rollout status deployment/local-git-mux --timeout=2m >/dev/null \
  && pass "HAProxy deployment is ready" \
  || fail "HAProxy deployment is not ready"

service_json=$(kubectl -n "$NAMESPACE" get service local-git-mux -o json)
jq -e --arg vip "$VIP" '
  .spec.type == "LoadBalancer" and
  .spec.allocateLoadBalancerNodePorts == false and
  (.spec.loadBalancerSourceRanges | sort) ==
    (["10.10.10.0/24", "10.20.20.0/24", "10.20.21.2/32"] | sort) and
  ([.spec.ports[].nodePort // empty] | length == 0) and
  ([.status.loadBalancer.ingress[].ip] | index($vip) != null) and
  ([.spec.ports[] | [.name, .port, .targetPort]] | sort) ==
    ([ ["https",443,"https"], ["ssh",22,"ssh"] ] | sort)
' >/dev/null <<<"$service_json" \
  && pass "LAN-only VIP has exactly HTTPS and SSH with no NodePorts" \
  || fail "LoadBalancer exposure does not match the intended shape"

[[ $(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') == restricted ]] \
  && pass "namespace enforces restricted Pod Security" \
  || fail "namespace does not enforce restricted Pod Security"

kubectl -n "$NAMESPACE" get ciliumnetworkpolicy local-git-mux-egress -o json | \
  jq -e '[.status.conditions[]? | select(.type == "Valid" and .status == "True")] | length > 0' >/dev/null \
  && pass "Cilium egress policy is valid" \
  || fail "Cilium egress policy is not valid"

status=$(curl -sS --resolve "$HOSTNAME:443:$VIP" --connect-timeout 5 --max-time 20 \
  -o /dev/null -w '%{http_code}' "https://$HOSTNAME/") \
  || fail "HTTPS did not pass through the mux to Cloudflare"
[[ $status != 000 ]] \
  && pass "HTTPS passes through Cloudflare with valid public TLS (HTTP $status)" \
  || fail "HTTPS returned no response"

banner=$(timeout 10 bash -c 'exec 3<>/dev/tcp/"$1"/22; IFS= read -r -t 5 line <&3; printf "%s" "$line"' _ "$VIP") \
  || fail "Forgejo SSH did not return a banner through the mux"
[[ $banner == SSH-* ]] \
  && pass "SSH reaches Forgejo through the same hostname VIP" \
  || fail "Unexpected SSH banner: $banner"

kubectl -n "$NAMESPACE" exec deployment/local-git-mux -- \
  nc -z -w 5 forgejo-ssh.forgejo.svc.cluster.local 22 >/dev/null \
  && pass "proxy can reach only the declared Forgejo SSH service" \
  || fail "proxy cannot reach Forgejo SSH"

if kubectl -n "$NAMESPACE" exec deployment/local-git-mux -- \
  nc -z -w 3 pocket-id.pocket-id.svc.cluster.local 80 >/dev/null 2>&1; then
  fail "proxy unexpectedly reached Pocket ID"
fi
pass "proxy cannot reach an undeclared cluster service"

if kubectl -n "$NAMESPACE" exec deployment/local-git-mux -- \
  wget -q -T 4 -O /dev/null https://example.com >/dev/null 2>&1; then
  fail "proxy unexpectedly reached an undeclared Internet host"
fi
pass "proxy cannot reach an undeclared Internet host"

overrides=$(jq -nc '{spec:{automountServiceAccountToken:false,enableServiceLinks:false,securityContext:{runAsNonRoot:true,runAsUser:100,runAsGroup:100,seccompProfile:{type:"RuntimeDefault"}},containers:[{name:"probe",image:"curlimages/curl:8.10.1",command:["sleep","300"],securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true,capabilities:{drop:["ALL"]}}}]}}')
kubectl -n default run "$PROBE" --restart=Never --image="$PROBE_IMAGE" \
  --overrides="$overrides" --command -- sleep 300 >/dev/null
kubectl -n default wait --for=condition=Ready "pod/$PROBE" --timeout=90s >/dev/null
if kubectl -n default exec "$PROBE" -- \
  curl -ksS --connect-timeout 2 --max-time 4 -o /dev/null "https://$VIP/" >/dev/null 2>&1; then
  fail "a Pod-CIDR source unexpectedly reached the LAN-only VIP"
fi
pass "Pod-CIDR sources cannot use the LAN-only VIP"

echo "All local Git mux checks passed."
