#!/usr/bin/env python3
"""Check rendered identities, safe automation policy, and source paths."""
import json
import re
import sys
from pathlib import Path

render_dir = Path(sys.argv[1])


def check_application(resource, child=False):
    name = resource["metadata"]["name"]
    spec = resource["spec"]
    expected = {"enabled": True, "prune": False, "selfHeal": True}
    if spec["syncPolicy"].get("automated") != expected:
        raise SystemExit(f"{name}: require auto-sync/self-heal with pruning disabled")
    if child and not {"Prune=confirm", "Delete=confirm"}.issubset(
        spec["syncPolicy"].get("syncOptions", [])
    ):
        raise SystemExit(f"{name}: missing destructive-operation confirmation guards")
    for rule in spec.get("ignoreDifferences", []):
        if rule.get("group") == "gateway.networking.k8s.io" and any(
            pointer in {"/spec", "/spec/listeners"}
            for pointer in rule.get("jsonPointers", [])
        ):
            raise SystemExit(f"{name}: broad Gateway API ignore hides configuration drift")
    for source in spec.get("sources", [spec.get("source", {})]):
        if "chart" in source and not re.fullmatch(
            r"v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?", source["targetRevision"]
        ):
            raise SystemExit(f"{name}: upstream chart version must be pinned")


bootstrap = json.loads((render_dir / "bootstrap.json").read_text())
roots = [r for r in bootstrap["extraObjects"] if r.get("kind") == "Application"]
if {r["metadata"]["name"] for r in roots} != {"apps", "infra", "apps-secrets", "infra-secrets"}:
    raise SystemExit("bootstrap must declare all four roots")
for resource in roots:
    check_application(resource)

for root in ("apps", "infra", "apps-secrets", "infra-secrets"):
    seen = set()
    for resource in json.loads((render_dir / f"{root}.json").read_text()):
        if not resource:
            continue
        metadata = resource["metadata"]
        identity = (
            resource["apiVersion"], resource["kind"],
            metadata.get("namespace", ""), metadata["name"],
        )
        if identity in seen:
            raise SystemExit(f"{root}: duplicate resource {identity}")
        seen.add(identity)
        if resource["kind"] != "Application":
            continue
        spec = resource["spec"]
        check_application(resource, child=True)
        for source in spec["sources"]:
            for value_file in source.get("helm", {}).get("valueFiles", []):
                if not value_file.startswith("$repo/"):
                    raise SystemExit(f"{metadata['name']}: unsupported values source")
                path = Path(value_file.removeprefix("$repo/"))
                if not path.is_file():
                    raise SystemExit(f"{metadata['name']}: missing values file {path}")
    print(f"{root}: {len(seen)} unique resources")
