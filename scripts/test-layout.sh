#!/usr/bin/env bash
# Exercise the enablement boundary: disabling a service must not drop its secrets.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp kubernetes/Chart.yaml kubernetes/values.yaml kubernetes/values.schema.json "$fixture/"
cp -r kubernetes/templates "$fixture/templates"
mkdir -p "$fixture/services/example/resources" "$fixture/services/example/secrets"
cat > "$fixture/services/example/service.yaml" <<'YAML'
owner: apps
enabled: false
components:
  - name: example
    chart: {repo: https://charts.example.invalid, name: example, version: '1.0.0'}
    valuesFile: values.yaml
YAML
printf '{}\n' > "$fixture/services/example/values.yaml"
cat > "$fixture/services/example/resources/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: example
YAML
cat > "$fixture/services/example/secrets/example.yaml" <<'YAML'
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: example
  namespace: example
spec:
  secretTemplates: []
YAML
render_count() {
    helm template fixture "$fixture" --set "owner=$1,render=$2" \
        | yq eval-all '[select(.kind != null)] | length'
}
[[ $(render_count apps resources) == 0 ]]
[[ $(render_count apps secrets) == 1 ]]
yq -i '.enabled = true' "$fixture/services/example/service.yaml"
[[ $(render_count apps resources) == 2 ]]
[[ $(render_count infra resources) == 0 ]]
[[ $(render_count infra secrets) == 0 ]]
yq -i '.components[0].oidc = {"enabled": true}' "$fixture/services/example/service.yaml"
job_count() {
    helm template fixture "$fixture" --set owner=apps \
        | yq eval-all '[select(.kind == "Job")] | length'
}
[[ $(job_count) == 0 ]]
yq -i '.components[0].oidc.bootstrapJob = true' "$fixture/services/example/service.yaml"
[[ $(job_count) == 1 ]]
yq -i '.components[0].oidc.bootstrapJob = false' "$fixture/services/example/service.yaml"
[[ $(job_count) == 0 ]]
mv "$fixture/services/example/values.yaml" "$fixture/services/example/missing.yaml"
if helm template fixture "$fixture" --set owner=apps > /dev/null 2> "$fixture/error"; then
    echo 'Missing values file unexpectedly passed validation' >&2
    exit 1
fi
grep -q 'values file missing or empty' "$fixture/error"
echo 'Service enablement, secret retention, owner selection, explicit OIDC execution, and missing-file checks passed.'
