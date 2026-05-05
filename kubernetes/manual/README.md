# manual config notes

GitOps covers most of the cluster, but a few apps require interactive setup that can't be expressed in YAML — passkey enrollment, first-admin bootstrap, OIDC client creation in the IDP, etc.

This directory holds **step-by-step rebuild notes** for each such app. The goal: if a service's state is wiped (PVC lost, ns nuked, restore failed), a human can follow the README in this directory and recreate the manual configuration from scratch in ~15 minutes per app.

## What goes here

For each app whose state isn't fully declared in `kubernetes/values/`, `kubernetes/secrets/`, etc.:

- A subfolder named after the app (`pocket-id/`, `argocd/`, ...)
- A `README.md` inside with:
  - **Pre-reqs** — what must already exist in the cluster (namespace, deployment, dependencies)
  - **Steps** — numbered actions (UI clicks, API calls, kubectl commands)
  - **Verification** — how to confirm each step worked
  - **State this creates** — what the manual setup persists (DB rows, files in PVC, etc.) so future-you knows what's protected
  - **Backup hint** — where the persisted state lives (PVC name, file path) for restic/snapshots

## What does NOT go here

- Anything declarable in YAML — that goes in the values/secrets dirs
- Secrets — those go in `kubernetes/secrets/<scope>/` SOPS-encrypted
- Day-2 ops or runbook material — separate concern

## Convention

When you do something manual in an app's UI/API, **update its README in the same session.** A note 3 weeks later is half-remembered; a note in the moment is gold.
