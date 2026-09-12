# Grafana admin credentials

The `infra-secrets` root owns `secrets/grafana-admin.yaml`. sops-secrets-operator decrypts it into the existing `monitoring/grafana` Secret. The Grafana chart references that Secret using `admin.existingSecret`; it no longer generates a password or password-dependent rollout checksum during rendering.

Retrieve the local emergency-login password when needed:

```sh
kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

The normal login remains Pocket ID. Use `/login?disableAutoLogin=true` for the local login flow. Dashboard and application state remain in the existing CNPG database.

## Rotation

Updating this Secret does not reset the password of an existing Grafana database user. Rotate its encrypted `admin-password`, sync only the SopsSecret, then use the installed Grafana CLI to reset the intended local admin account with the same password. Supply it through stdin (`admin reset-admin-password --password-from-stdin`), never command-line arguments or logs. Use `--homepath /usr/share/grafana --config /etc/grafana/grafana.ini` so the CLI uses the configured PostgreSQL database and injected database credentials. Verify authenticated access afterward. Do not delete or recreate the database to reset credentials.

For restore, deploy the SopsSecret before Grafana. A restored database may have an older password; reconcile it explicitly with the Secret. Auto-sync remains disabled under the repository refactoring rules.
