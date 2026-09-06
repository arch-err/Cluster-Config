# Platform capabilities

Platform directories group shared capabilities by purpose: GitOps, identity, networking, storage, observability, and hardware integration. Each deployable or retained unit has its own `service.yaml`.

This directory is not a separate Helm chart. The source chart is rooted at [kubernetes/](../README.md). Folder placement does not determine Argo ownership; the explicit `owner` field preserves the existing parent Application.
