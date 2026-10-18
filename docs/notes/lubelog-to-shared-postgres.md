# lubelog: dedicated cluster to the shared Postgres cluster

One-off migration runbook. Commands are fish. Lubelog already runs on Postgres (`lubelog-db`), so this is a database move, not a SQLite conversion.

## Where the connection lives

Lubelog reads `POSTGRES_CONNECTION` from `/App/data/config/serverConfig.json` on its PVC, not from the pod environment. Lubelog adds that file after the environment variables, so it overrides them. Setting the variable in the HelmRelease or ExternalSecret would be ignored. The cutover edits the file in place.

## Prerequisites

1. The `lubelog` Bitwarden item has a `POSTGRES_PASSWORD` key (letters and digits only).
2. The tenant commit is on `main` and applied. Check:
   ```fish
   kubectl get externalsecret,databaserole,database -n dbms | rg lubelog
   ```
   All three must be synced and `APPLIED: true`.

## Steps

1. Stop the app so nothing writes during the copy:
   ```fish
   flux suspend helmrelease lubelog -n selfhosted
   kubectl scale deploy/lubelog -n selfhosted --replicas=0
   ```

2. Copy the data (small; streamed through your machine):
   ```fish
   set PW (kubectl get secret -n dbms postgres-lubelog-secret -o jsonpath='{.data.password}' | base64 -d)
   set PRIMARY (kubectl get cluster.postgresql.cnpg.io -n selfhosted lubelog-db -o jsonpath='{.status.currentPrimary}')
   kubectl exec -n selfhosted $PRIMARY -c postgres -- pg_dump -Fc -d lubelog | kubectl exec -i -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW pg_restore -h postgres-rw -U lubelog -d lubelog --no-owner --exit-on-error
   ```

3. Compare row counts between the old and new databases:
   ```fish
   kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -d lubelog -tAc "select (select count(*) from app.vehicles), (select count(*) from app.userrecords), (select count(*) from app.odometerrecords), (select count(*) from app.servicerecords), (select count(*) from app.gasrecords)"
   kubectl exec -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW psql -h postgres-rw -U lubelog -d lubelog -tAc "select (select count(*) from app.vehicles), (select count(*) from app.userrecords), (select count(*) from app.odometerrecords), (select count(*) from app.servicerecords), (select count(*) from app.gasrecords)"
   ```
   The two lines must match.

4. Start the app, then point it at the shared cluster. The config reloads on change; restart to be safe:
   ```fish
   kubectl scale deploy/lubelog -n selfhosted --replicas=1
   kubectl rollout status deploy/lubelog -n selfhosted
   set NEW "Host=postgres-rw.dbms.svc.cluster.local;Port=5432;Username=lubelog;Password=$PW;Database=lubelog"
   kubectl exec -n selfhosted deploy/lubelog -- env NEW="$NEW" sh -c 'cd /App/data/config && cp serverConfig.json serverConfig.json.bak && sed -i "s|\"POSTGRES_CONNECTION\": *\"[^\"]*\"|\"POSTGRES_CONNECTION\": \"$NEW\"|" serverConfig.json && grep -c "postgres-rw.dbms" serverConfig.json'
   flux resume helmrelease lubelog -n selfhosted
   kubectl rollout restart deploy/lubelog -n selfhosted
   ```
   The `grep` must print `1`. If it prints `0`, the file layout differs; restore from `serverConfig.json.bak` and edit by hand.

5. Verify: sign in, check the vehicles and recent records, add a test record. Confirm the new database is receiving traffic:
   ```fish
   kubectl exec -n dbms postgres-1 -c postgres -- psql -tAc "select usename, state, count(*) from pg_stat_activity where datname='lubelog' group by 1,2"
   ```
   A connection timeout in the app log means the Cilium client rule or the reply rule is missing.

## Rollback

Restore the backup config and restart:
```fish
kubectl exec -n selfhosted deploy/lubelog -- sh -c 'cd /App/data/config && cp serverConfig.json.bak serverConfig.json'
kubectl rollout restart deploy/lubelog -n selfhosted
```
The old `lubelog-db` cluster stays untouched until the cleanup, so this returns to the pre-migration data. Changes made on the shared cluster after the cutover are lost.

## Cleanup (a few days later)

1. Delete the config backup, which still holds the old password:
   ```fish
   kubectl exec -n selfhosted deploy/lubelog -- rm /App/data/config/serverConfig.json.bak
   ```
2. In `apps/selfhosted/lubelog/ks.yaml`, remove `components/postgres`, `healthCheckExprs`, the `cnpg-barman-cloud` dependency and `PG_BACKUP_MINUTE`. Pruning deletes the old cluster and its PVCs.
3. The old Barman archive under `s3://cnpg-6u9f/lubelog/` and the NFS dumps remain until you remove them.
