# Configured services

Generated from the committed component lists during the 2026-09-06 cleanup. “Enabled” means the local chart renders the component; it is **not** a live health assertion. Values for disabled components remain available for reference.

## Enabled infra components (21)

| Component | Namespace | Configured hostname | Values |
| --- | --- | --- | --- |
| `cilium` | `kube-system` | hubble.infra.home | [values](../kubernetes/values/infra/cilium.yaml) |
| `cert-manager` | `cert-manager` | — | [values](../kubernetes/values/infra/cert-manager.yaml) |
| `trust-manager` | `cert-manager` | — | [values](../kubernetes/values/infra/trust-manager.yaml) |
| `cnpg` | `cnpg-system` | — | [values](../kubernetes/values/infra/cnpg.yaml) |
| `argocd` | `argocd` | argocd.infra.home | [values](../kubernetes/values/infra/argocd.yaml) |
| `sops-secrets-operator` | `sops-secrets-operator` | — | [values](../kubernetes/values/infra/sops-secrets-operator.yaml) |
| `agent-rbac` | `agent-access` | — | [values](../kubernetes/values/infra/agent-rbac.yaml) |
| `local-path-provisioner` | `local-path-storage` | — | [values](../kubernetes/values/infra/local-path-provisioner.yaml) |
| `local-bulk` | `local-bulk-storage` | — | [values](../kubernetes/values/infra/local-bulk.yaml) |
| `metrics-server` | `kube-system` | — | [values](../kubernetes/values/infra/metrics-server.yaml) |
| `kube-state-metrics` | `monitoring` | — | [values](../kubernetes/values/infra/kube-state-metrics.yaml) |
| `prometheus-node-exporter` | `monitoring` | — | [values](../kubernetes/values/infra/prometheus-node-exporter.yaml) |
| `prometheus` | `monitoring` | — | [values](../kubernetes/values/infra/prometheus.yaml) |
| `loki` | `monitoring` | — | [values](../kubernetes/values/infra/loki.yaml) |
| `alloy` | `monitoring` | — | [values](../kubernetes/values/infra/alloy.yaml) |
| `grafana` | `monitoring` | grafana.infra.home | [values](../kubernetes/values/infra/grafana.yaml) |
| `homepage-infra` | `homepage-infra` | homepage.infra.home | [values](../kubernetes/values/infra/homepage-infra.yaml) |
| `homepage-admin` | `homepage-admin` | admin.infra.home | [values](../kubernetes/values/infra/homepage-admin.yaml) |
| `n8n` | `n8n` | n8n.infra.home | [values](../kubernetes/values/infra/n8n.yaml) |
| `n8n-oauth2` | `n8n` | — | [values](../kubernetes/values/infra/n8n-oauth2.yaml) |
| `error-pages-infra` | `error-pages-infra` | *.infra.home | [values](../kubernetes/values/infra/error-pages-infra.yaml) |

## Disabled infra components (1)

| Component | Namespace | Configured hostname | Values |
| --- | --- | --- | --- |
| `kadalu` | `kadalu` | — | [values](../kubernetes/values/infra/kadalu.yaml) |

## Enabled apps components (21)

| Component | Namespace | Configured hostname | Values |
| --- | --- | --- | --- |
| `audiobookshelf-v2` | `audiobookshelf-v2` | audiobookshelf.apps.home | [values](../kubernetes/values/apps/audiobookshelf-v2.yaml) |
| `immich` | `immich` | immich.apps.home | [values](../kubernetes/values/apps/immich.yaml) |
| `ntfy` | `ntfy` | ntfy.apps.home | [values](../kubernetes/values/apps/ntfy.yaml) |
| `homepage` | `homepage` | homepage.apps.home | [values](../kubernetes/values/apps/homepage.yaml) |
| `pocket-id` | `pocket-id` | auth.apps.home | [values](../kubernetes/values/apps/pocket-id.yaml) |
| `excalidash` | `excalidash` | excalidash.apps.home | [values](../kubernetes/values/apps/excalidash.yaml) |
| `it-tools` | `it-tools` | it-tools.apps.home | [values](../kubernetes/values/apps/it-tools.yaml) |
| `cyberchef` | `cyberchef` | cyberchef.apps.home | [values](../kubernetes/values/apps/cyberchef.yaml) |
| `papra` | `papra` | papra.apps.home | [values](../kubernetes/values/apps/papra.yaml) |
| `calibre-web` | `calibre-web` | calibre.apps.home | [values](../kubernetes/values/apps/calibre-web.yaml) |
| `calibre-web-oauth2` | `calibre-web` | — | [values](../kubernetes/values/apps/calibre-web-oauth2.yaml) |
| `booklore` | `booklore` | booklore.apps.home | [values](../kubernetes/values/apps/booklore.yaml) |
| `booklore-oauth2` | `booklore` | — | [values](../kubernetes/values/apps/booklore-oauth2.yaml) |
| `home-assistant` | `home-assistant` | ha.apps.home | [values](../kubernetes/values/apps/home-assistant.yaml) |
| `home-assistant-mdns` | `home-assistant-mdns` | — | [values](../kubernetes/values/apps/home-assistant-mdns.yaml) |
| `metube` | `metube` | metube.apps.home | [values](../kubernetes/values/apps/metube.yaml) |
| `metube-oauth2` | `metube` | — | [values](../kubernetes/values/apps/metube-oauth2.yaml) |
| `jellyfin` | `jellyfin` | jellyfin.apps.home | [values](../kubernetes/values/apps/jellyfin.yaml) |
| `navidrome` | `navidrome` | navidrome.apps.home | [values](../kubernetes/values/apps/navidrome.yaml) |
| `navidrome-oauth2` | `navidrome` | — | [values](../kubernetes/values/apps/navidrome-oauth2.yaml) |
| `error-pages` | `error-pages` | *.apps.home | [values](../kubernetes/values/apps/error-pages.yaml) |

## Disabled apps components (20)

| Component | Namespace | Configured hostname | Values |
| --- | --- | --- | --- |
| `matrix` | `matrix` | matrix.apps.home | [values](../kubernetes/values/apps/matrix.yaml) |
| `hookshot` | `matrix` | hookshot.apps.home | [values](../kubernetes/values/apps/hookshot.yaml) |
| `agent-vault` | `agent-vault` | agent-vault.apps.home | [values](../kubernetes/values/apps/agent-vault.yaml) |
| `stirling-pdf` | `stirling-pdf` | stirling-pdf.apps.home | [values](../kubernetes/values/apps/stirling-pdf.yaml) |
| `pingvin-share` | `pingvin-share` | pingvin.apps.home | [values](../kubernetes/values/apps/pingvin-share.yaml) |
| `qbittorrent` | `qbittorrent` | qbittorrent.infra.home | [values](../kubernetes/values/apps/qbittorrent.yaml) |
| `syncthing` | `syncthing` | syncthing.apps.home | [values](../kubernetes/values/apps/syncthing.yaml) |
| `syncthing-oauth2` | `syncthing` | — | [values](../kubernetes/values/apps/syncthing-oauth2.yaml) |
| `vaultwarden` | `vaultwarden` | vaultwarden.apps.home | [values](../kubernetes/values/apps/vaultwarden.yaml) |
| `samba` | `samba` | — | [values](../kubernetes/values/apps/samba.yaml) |
| `kanban` | `kanban` | kanban.apps.home | [values](../kubernetes/values/apps/kanban.yaml) |
| `mattermost` | `mattermost` | agents.apps.home | [values](../kubernetes/values/apps/mattermost.yaml) |
| `mosquitto` | `mqtt` | — | [values](../kubernetes/values/apps/mosquitto.yaml) |
| `zigbee2mqtt` | `zigbee2mqtt` | zigbee2mqtt.infra.home | [values](../kubernetes/values/apps/zigbee2mqtt.yaml) |
| `zigbee2mqtt-oauth2` | `zigbee2mqtt` | — | [values](../kubernetes/values/apps/zigbee2mqtt-oauth2.yaml) |
| `hermes-oauth2` | `hermes` | hermes.infra.home | [values](../kubernetes/values/apps/hermes-oauth2.yaml) |
| `t3-oauth2` | `t3` | t3.infra.home | [values](../kubernetes/values/apps/t3-oauth2.yaml) |
| `kivra-sync` | `kivra-sync` | kivra-sync.infra.home | [values](../kubernetes/values/apps/kivra-sync.yaml) |
| `kivra-sync-oauth2` | `kivra-sync` | — | [values](../kubernetes/values/apps/kivra-sync-oauth2.yaml) |
| `protonmail-bridge` | `protonmail-bridge` | — | [values](../kubernetes/values/apps/protonmail-bridge.yaml) |

Separately disabled extras: `arr`, `hermes`, `kanban`, `kivra-sync`, `mattermost`, `mosquitto`, `protonmail-bridge`, `samba`, `stirling-pdf`, `t3`, `zigbee2mqtt`.

## Resources outside this list

The platform also renders resources from `extras`, including static storage bindings, CoreDNS, gateways, and some app-specific workloads. The four bootstrap root Applications and external Docker-host services are not component rows. Consult [Kubernetes](kubernetes.md) and the two configuration files for those resources.

When changing component enablement, refresh this table from `components` and `disabledComponents`; check `disabledExtras` independently. Do not infer that disabled-service PVCs or externally supplied claims have been deleted.
