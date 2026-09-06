# Kubernetes source chart

`Chart.yaml` is at this level so Helm can read the service directories using its ordinary `.Files` interface. Shared renderers live in `templates/`; service-specific inputs and resource templates live beside each service.

| Root Application | Values file | Output |
| --- | --- | --- |
| `apps` | `releases/apps.yaml` | Applications and supporting resources owned by apps |
| `infra` | `releases/infra.yaml` | Applications and supporting resources owned by infra |
| `apps-secrets` | `releases/apps-secrets.yaml` | Secret manifests from services with `owner: apps` |
| `infra-secrets` | `releases/infra-secrets.yaml` | Secret manifests from services with `owner: infra` |

`owner` preserves existing Argo ownership. For example, `services/n8n/` still belongs to `infra`, while `platform/identity/pocket-id/` belongs to `apps`.

See [chart details](../docs/platform-chart.md) and [adding services](../docs/adding-apps.md). Do not sync these roots to propagate source-path changes while the migration gate is blocked.
