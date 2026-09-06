# Platform chart

This chart generates ArgoCD Applications and supporting resources from the component lists in `kubernetes/infra.yaml` and `kubernetes/apps.yaml`.

See the maintained guides:

- [Chart inputs and templates](../../docs/platform-chart.md)
- [Adding applications, OIDC, and databases](../../docs/adding-apps.md)
- [Storage and retention](../../docs/pvc-reclaim-policy.md)
- [Pocket ID manual bootstrap](../manual/pocket-id/README.md)

Run `just check` from the repository root to lint and render both configurations.
