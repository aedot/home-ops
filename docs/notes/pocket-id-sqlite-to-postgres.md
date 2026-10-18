# pocket-id: SQLite to the shared Postgres cluster

One-off migration runbook. Commands are fish. The SQLite file stays on the PVC until you delete it, so rollback is a revert.

## Stages

1. **Stage A** (`externalsecret.yaml`): adds `DB_CONNECTION_STRING` for the shared cluster to `pocket-id-secret`. Harmless while the HelmRelease still sets its own `DB_CONNECTION_STRING` (`env` wins over `envFrom`). Merge and push this alone first.
2. **Data move**: export from SQLite, import into Postgres with the app stopped.
3. **Stage B** (`helmrelease.yaml`, `ks.yaml`): drops the SQLite `DB_CONNECTION_STRING` and makes `pocket-id` wait on `pocket-id-postgres`. Merge after the import succeeds.

## Steps

1. After stage A, confirm the secret has the Postgres URI (prints key names only):
   ```fish
   kubectl get secret -n security pocket-id-secret -o json | jq -r '.data | keys[]'
   ```
   `DB_CONNECTION_STRING` must be listed. The pod restarts once through Reloader and still runs on SQLite.

2. Export from the running SQLite instance onto the PVC:
   ```fish
   kubectl exec -n security deploy/pocket-id -- /app/pocket-id export -p /data/pocket-id-export.zip
   ```

3. Stop the app. Suspend the HelmRelease so Flux does not scale it back:
   ```fish
   flux suspend helmrelease pocket-id -n security
   kubectl scale deploy/pocket-id -n security --replicas=0
   ```

4. Import into Postgres from a one-off pod built from the live Deployment (same image, env, PVC and labels, so the Cilium client rule matches). It uses the Postgres URI from the secret:
   ```fish
   kubectl get deploy -n security pocket-id -o json | jq '{apiVersion:"v1",kind:"Pod",metadata:{name:"pocket-id-import",namespace:"security",labels:.spec.template.metadata.labels},spec:(.spec.template.spec | .restartPolicy="Never" | .containers[0] |= (.command=["/app/pocket-id"] | .args=["import","-p","/data/pocket-id-export.zip","--yes"] | .env |= map(select(.name!="DB_CONNECTION_STRING")) | del(.livenessProbe,.readinessProbe,.startupProbe)))}' | kubectl create -f -
   kubectl wait -n security pod/pocket-id-import --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
   kubectl logs -n security pocket-id-import
   ```
   A connection timeout means the Cilium client policy or a reply-flow rule is missing. A missing-schema or non-empty-database error means the importer expects different preconditions: start the app once against Postgres to run migrations, scale it down again, and retry with `--forcefully-acquire-lock`.

5. Merge stage B and push, then resume:
   ```fish
   flux resume helmrelease pocket-id -n security
   just kube reconcile
   kubectl get pods -n security
   ```

6. Verify: sign in at the SSO URL, check a passkey login, an OIDC client and the uploaded images. Confirm the database in use:
   ```fish
   kubectl logs -n security deploy/pocket-id | rg -i "postgres|sqlite"
   ```

7. Clean up:
   ```fish
   kubectl delete pod -n security pocket-id-import
   kubectl exec -n security deploy/pocket-id -- rm /data/pocket-id-export.zip
   ```
   Leave `pocket-id.db*` on the PVC for about a week, then delete it. Kopiur snapshots keep older copies either way.

## Rollback

Revert stage B and resume the HelmRelease. The app returns to the untouched SQLite file. Anything changed in Postgres after the cutover is lost.
