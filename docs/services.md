# Service inventory

This lists desired source configuration, not live health. Directory placement groups related files; `owner` preserves Argo root ownership. Secret output remains independent of service enablement.

| Directory | Argo owner | Enabled | Components |
| --- | --- | --- | --- |
| [platform/argocd](../kubernetes/platform/argocd/service.yaml) | `infra` | yes | `argocd` |
| [platform/argocd/agent-rbac](../kubernetes/platform/argocd/agent-rbac/service.yaml) | `infra` | yes | `agent-rbac` |
| [platform/hardware/zigbee-device](../kubernetes/platform/hardware/zigbee-device/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [platform/identity/cert-manager](../kubernetes/platform/identity/cert-manager/service.yaml) | `infra` | yes | `cert-manager` |
| [platform/identity/pocket-id](../kubernetes/platform/identity/pocket-id/service.yaml) | `apps` | yes | `pocket-id` |
| [platform/identity/sops-secrets-operator](../kubernetes/platform/identity/sops-secrets-operator/service.yaml) | `infra` | yes | `sops-secrets-operator` |
| [platform/identity/trust-manager](../kubernetes/platform/identity/trust-manager/service.yaml) | `infra` | yes | `trust-manager` |
| [platform/networking/cilium](../kubernetes/platform/networking/cilium/service.yaml) | `infra` | yes | `cilium` |
| [platform/networking/coredns](../kubernetes/platform/networking/coredns/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [platform/networking/error-pages](../kubernetes/platform/networking/error-pages/service.yaml) | `infra` | yes | `error-pages-infra` |
| [platform/networking/error-pages-apps](../kubernetes/platform/networking/error-pages-apps/service.yaml) | `apps` | yes | `error-pages` |
| [platform/networking/external-services](../kubernetes/platform/networking/external-services/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [platform/networking/gateways](../kubernetes/platform/networking/gateways/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [platform/observability/alloy](../kubernetes/platform/observability/alloy/service.yaml) | `infra` | yes | `alloy` |
| [platform/observability/grafana](../kubernetes/platform/observability/grafana/service.yaml) | `infra` | yes | `grafana` |
| [platform/observability/homepage](../kubernetes/platform/observability/homepage/service.yaml) | `infra` | yes | `homepage-infra`, `homepage-admin` |
| [platform/observability/kube-state-metrics](../kubernetes/platform/observability/kube-state-metrics/service.yaml) | `infra` | yes | `kube-state-metrics` |
| [platform/observability/loki](../kubernetes/platform/observability/loki/service.yaml) | `infra` | yes | `loki` |
| [platform/observability/metrics-server](../kubernetes/platform/observability/metrics-server/service.yaml) | `infra` | yes | `metrics-server` |
| [platform/observability/namespace](../kubernetes/platform/observability/namespace/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [platform/observability/node-exporter](../kubernetes/platform/observability/node-exporter/service.yaml) | `infra` | yes | `prometheus-node-exporter` |
| [platform/observability/prometheus](../kubernetes/platform/observability/prometheus/service.yaml) | `infra` | yes | `prometheus` |
| [platform/storage/cnpg](../kubernetes/platform/storage/cnpg/service.yaml) | `infra` | yes | `cnpg` |
| [platform/storage/local-bulk](../kubernetes/platform/storage/local-bulk/service.yaml) | `infra` | yes | `local-bulk` |
| [platform/storage/local-path-provisioner](../kubernetes/platform/storage/local-path-provisioner/service.yaml) | `infra` | yes | `local-path-provisioner` |
| [services/audiobookshelf](../kubernetes/services/audiobookshelf/service.yaml) | `apps` | yes | `audiobookshelf-v2` |
| [services/booklore](../kubernetes/services/booklore/service.yaml) | `apps` | yes | `booklore`, `booklore-oauth2` |
| [services/calibre-web](../kubernetes/services/calibre-web/service.yaml) | `apps` | yes | `calibre-web`, `calibre-web-oauth2` |
| [services/cyberchef](../kubernetes/services/cyberchef/service.yaml) | `apps` | yes | `cyberchef` |
| [services/excalidash](../kubernetes/services/excalidash/service.yaml) | `apps` | yes | `excalidash` |
| [services/home-assistant](../kubernetes/services/home-assistant/service.yaml) | `apps` | yes | `home-assistant`, `home-assistant-mdns` |
| [services/homepage](../kubernetes/services/homepage/service.yaml) | `apps` | yes | `homepage` |
| [services/immich](../kubernetes/services/immich/service.yaml) | `apps` | yes | `immich` |
| [services/it-tools](../kubernetes/services/it-tools/service.yaml) | `apps` | yes | `it-tools` |
| [services/jellyfin](../kubernetes/services/jellyfin/service.yaml) | `apps` | yes | `jellyfin` |
| [services/metube](../kubernetes/services/metube/service.yaml) | `apps` | yes | `metube`, `metube-oauth2` |
| [services/n8n](../kubernetes/services/n8n/service.yaml) | `infra` | yes | `n8n`, `n8n-oauth2` |
| [services/navidrome](../kubernetes/services/navidrome/service.yaml) | `apps` | yes | `navidrome`, `navidrome-oauth2` |
| [services/ntfy](../kubernetes/services/ntfy/service.yaml) | `apps` | yes | `ntfy` |
| [services/paperless-ngx](../kubernetes/services/paperless-ngx/service.yaml) | `apps` | no | Supporting resources/settings only |
| [services/papra](../kubernetes/services/papra/service.yaml) | `apps` | yes | `papra` |
| [services/rocky](../kubernetes/services/rocky/service.yaml) | `infra` | yes | Supporting resources/settings only |
| [services/stirling-pdf](../kubernetes/services/stirling-pdf/service.yaml) | `apps` | yes | `stirling-pdf` |
| [services/syncthing](../kubernetes/services/syncthing/service.yaml) | `apps` | no | `syncthing`, `syncthing-oauth2` |

The live Application inventory differs from this desired list because retained/pending-deletion Applications exist. See [the baseline](refactoring.md) before drawing conclusions about deployment state.
