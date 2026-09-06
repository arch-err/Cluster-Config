#!/usr/bin/env python3
"""Check rendered identities, manual-sync policy, and repository source paths."""
import json
import sys
from pathlib import Path

render_dir = Path(sys.argv[1])
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
        if spec["syncPolicy"]["automated"].get("enabled") is not False:
            raise SystemExit(f"{metadata['name']}: automatic sync must remain disabled")
        for source in spec["sources"]:
            for value_file in source.get("helm", {}).get("valueFiles", []):
                if not value_file.startswith("$repo/"):
                    raise SystemExit(f"{metadata['name']}: unsupported values source")
                path = Path(value_file.removeprefix("$repo/"))
                if not path.is_file():
                    raise SystemExit(f"{metadata['name']}: missing values file {path}")
    print(f"{root}: {len(seen)} unique resources")
