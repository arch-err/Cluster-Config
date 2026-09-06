#!/usr/bin/env bash
# Validate sources and renders without contacting or changing the cluster.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT

for root in infra apps infra-secrets apps-secrets; do
    helm lint kubernetes -f "kubernetes/releases/${root}.yaml" --strict
    helm template "$root" kubernetes -f "kubernetes/releases/${root}.yaml" \
        | yq eval-all -o=json -I=0 '[.]' > "$check_dir/${root}.json"
done
python3 scripts/check-layout.py "$check_dir"
./scripts/test-layout.sh

for script in scripts/*; do
    if [[ -f "$script" ]] && head -n 1 "$script" | grep -q 'bash'; then
        bash -n "$script"
    fi
done

echo 'All four root renders, source references, and Bash syntax checks passed.'
