# teslamate: dedicated cluster to the shared Postgres cluster

One-off migration runbook. Commands are fish. Teslamate already runs on Postgres (`teslamate-db`), so this is a database move. The database is about 1.6GB (a 200MB compressed dump).

## What differs from the other apps

- **No superuser needed.** The old `teslamate` role is a superuser, but teslamate only runs `CREATE EXTENSION IF NOT EXISTS cube` and `earthdistance`. `earthdistance` is not a trusted extension, so the `Database` resource creates both as the operator; the migrations then skip them. A non-superuser role was tested against pre-created extensions and `ll_to_earth()` works.
- **Dump excludes the extensions** (`--exclude-extension`), since they already exist in the target.
- **Connection lives only in the environment.** There is no config file on a PVC.
- **Grafana reads this database** through a `GrafanaDatasource` that uses the same role. It must move too.
- **Pick a quiet time.** Teslamate does not record while it is stopped. Do this while the car is parked and asleep.

## Stages

1. **Stage 1** (tenant): database with extensions, role, ExternalSecret, client and reply policies, `pg_hba` line, dump entry. Safe to merge on its own.
2. **Cutover commit** (prepared after stage 1 is applied): `DATABASE_HOST` and `DATABASE_PASS` move into `teslamate-secret`, the old `-db-app` references leave the HelmRelease, the Grafana datasource points at `postgres-r.dbms.svc.cluster.local` with its password from `teslamate-secret`, and `teslamate` waits on `teslamate-postgres`.
3. **Cleanup** (a few days later): drop the postgres component, the health check, the Barman dependency, `PG_BACKUP_MINUTE` and `teslamate-db-allow-grafana`.

## Prerequisites

1. The `teslamate` Bitwarden item has `POSTGRES_PASSWORD` (letters and digits only).
2. Stage 1 is on `main` and applied:
   ```fish
   kubectl get externalsecret,databaserole,database -n dbms | rg teslamate
   ```
   All synced and `APPLIED: true`. Confirm the extensions arrived:
   ```fish
   kubectl exec -n dbms postgres-1 -c postgres -- psql -d teslamate -tAc "select extname from pg_extension order by 1"
   ```
   Expect `cube`, `earthdistance` and `plpgsql`.

## Steps

1. Stop the app:
   ```fish
   flux suspend helmrelease teslamate -n selfhosted
   kubectl scale deploy/teslamate -n selfhosted --replicas=0
   ```

2. Copy the database (streamed through your machine):
   ```fish
   set PW (kubectl get secret -n dbms postgres-teslamate-secret -o jsonpath='{.data.password}' | base64 -d)
   set PRIMARY (kubectl get cluster.postgresql.cnpg.io -n selfhosted teslamate-db -o jsonpath='{.status.currentPrimary}')
   kubectl exec -n selfhosted $PRIMARY -c postgres -- pg_dump -Fc -d teslamate --exclude-extension=cube --exclude-extension=earthdistance | kubectl exec -i -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW pg_restore -h postgres-rw -U teslamate -d teslamate --no-owner --no-privileges --clean --if-exists --exit-on-error
   ```
   `--no-privileges` is required: the old database carries `ALTER DEFAULT PRIVILEGES FOR ROLE postgres`, which a non-superuser cannot restore. `--clean --if-exists` makes the command safe to rerun after a partial restore.

3. Compare row counts for every table. The two files must be identical:
   ```fish
   set Q "select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"
   kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -d teslamate -tAc "$Q" > /tmp/old-teslamate.txt
   kubectl exec -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW psql -h postgres-rw -U teslamate -d teslamate -tAc "$Q" > /tmp/new-teslamate.txt
   diff /tmp/old-teslamate.txt /tmp/new-teslamate.txt; and echo identical
   ```

4. Merge the cutover commit, push, reconcile while the HelmRelease is still suspended, and check the secret before resuming:
   ```fish
   just kube reconcile
   kubectl get secret -n selfhosted teslamate-secret -o json | jq -r '.data | keys[]' | rg DATABASE
   flux resume helmrelease teslamate -n selfhosted
   kubectl rollout status deploy/teslamate -n selfhosted
   ```
   `DATABASE_HOST` and `DATABASE_PASS` must be listed before you resume.

5. Verify: open TeslaMate, confirm it connects to the car, and look at a recent drive. Open a TeslaMate dashboard in Grafana. Confirm the traffic:
   ```fish
   kubectl exec -n dbms postgres-1 -c postgres -- psql -tAc "select datname, usename, state, count(*) from pg_stat_activity where usename='teslamate' group by 1,2,3"
   kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -tAc "select usename, state, count(*) from pg_stat_activity where usename='teslamate' group by 1,2"
   ```
   The second query should return nothing.

## Rollback

Revert the cutover commit, push, suspend and scale as in step 1, and resume. The old cluster is untouched until cleanup. Anything recorded on the shared cluster after the cutover is lost.

## Cleanup (a few days later)

1. In `apps/selfhosted/teslamate/ks.yaml`, remove `components/postgres`, `healthCheckExprs`, the `cnpg-barman-cloud` dependency and `PG_BACKUP_MINUTE`. Remove `teslamate-db-allow-grafana` from `app/networkpolicy.yaml`. Pruning deletes the old cluster and its volumes.
2. The old Barman archive under `s3://cnpg-6u9f/teslamate/` and the NFS dumps remain until you remove them.
