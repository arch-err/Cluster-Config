#!/usr/bin/env bash
# Validate local configuration without contacting or changing the cluster.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for scope in infra apps; do
    helm lint kubernetes/platform -f "kubernetes/${scope}.yaml" --strict
    helm template "$scope" kubernetes/platform -f "kubernetes/${scope}.yaml" >/dev/null
done

for script in scripts/*; do
    if [[ -f "$script" ]] && head -n 1 "$script" | grep -q 'bash'; then
        bash -n "$script"
    fi
done

echo 'Local chart renders and Bash syntax checks passed.'
