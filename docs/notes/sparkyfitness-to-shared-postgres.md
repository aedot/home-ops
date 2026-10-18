# sparkyfitness: dedicated cluster to the shared Postgres cluster

One-off migration runbook. Commands are fish. SparkyFitness already runs on Postgres (`sparkyfitness-db`, 17MB, schemas `public`, `auth`, `system`).

## What differs from the other apps

- **It does not need superuser.** The dedicated cluster ran it as `postgres` only because `PG_SUPERUSER: "true"` was set. Upstream supports a non-superuser setup: the database **owner** runs migrations and manages row-level security (RLS), and a separate **app** role is used at runtime. No extensions are needed. This move uses that setup with two roles, created here so the app skips its own `CREATE ROLE`:
  - `sparkyfitness_admin`: owns the database and every table (`DB_USER`).
  - `sparkyfitness_app`: runtime role (`APP_DB_USER`), subject to RLS.
- **Ownership changes, and so does RLS exposure.** Today 49 tables are owned by `postgres` and 64 by the old `sparkyfitness` role. RLS applies to non-owners, and all 177 policies are `TO public` with 96 tables under RLS. The old app role owned 64 of them, so it bypassed their policies. After the move the admin owns everything and the app role is subject to every policy. That is upstream's intended setup, but it is a behaviour change: test thoroughly.
- **Dump role.** `pg_read_all_data` does not bypass RLS, so the shared `backup` role gets `BYPASSRLS` (stage 1) or pg_dump fails on the RLS tables.
- **Two passwords**, both in the Bitwarden `sparkyfitness` item: `POSTGRES_ADMIN_PASSWORD` and `POSTGRES_APP_PASSWORD` (letters and digits only).

## Stages

1. **Stage 1** (tenant): database, two roles, two ExternalSecrets, client and reply policies, two `pg_hba` lines, dump entry, `BYPASSRLS` on `backup`. Safe to merge on its own.
2. **Cutover commit** (prepared after stage 1 is applied): the `SPARKY_FITNESS_DB_*` and `SPARKY_FITNESS_APP_DB_*` variables move into `sparkyfitness-secret` (host `postgres-rw.dbms.svc.cluster.local`, database `sparkyfitness`), the old `-db-app` and `-db-superuser` references leave the HelmRelease, and `sparkyfitness` waits on `sparkyfitness-postgres`.
3. **Cleanup** (a few days later): drop the postgres component, the health check, the Barman dependency, `PG_BACKUP_MINUTE`, `PG_SUPERUSER` and the CronJob patch in `app/kustomization.yaml`.

## Prerequisites

1. The `sparkyfitness` Bitwarden item has both password keys.
2. Stage 1 is on `main` and applied, including the `backup` role change:
   ```fish
   kubectl get externalsecret,databaserole,database -n dbms | rg "sparkyfitness|backup"
   kubectl exec -n dbms postgres-1 -c postgres -- psql -tAc "select rolname, rolbypassrls from pg_roles where rolname='backup'"
   ```
   Everything synced and `APPLIED: true`; `backup` must show `t`. A "secrets is forbidden" message on a role clears by itself after a minute.

## Steps

1. Stop the server (the frontend does not use the database):
   ```fish
   flux suspend helmrelease sparkyfitness -n selfhosted
   kubectl scale deploy/sparkyfitness-server -n selfhosted --replicas=0
   ```

2. Copy the database, restoring as the admin role so it owns everything:
   ```fish
   set PW (kubectl get secret -n dbms postgres-sparkyfitness-admin-secret -o jsonpath='{.data.password}' | base64 -d)
   set PRIMARY (kubectl get cluster.postgresql.cnpg.io -n selfhosted sparkyfitness-db -o jsonpath='{.status.currentPrimary}')
   kubectl exec -n selfhosted $PRIMARY -c postgres -- pg_dump -Fc -d sparkyfitness | kubectl exec -i -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW pg_restore -h postgres-rw -U sparkyfitness_admin -d sparkyfitness --no-owner --no-privileges --clean --if-exists --exit-on-error
   ```
   `--no-privileges` and `--no-owner` are required for a non-superuser restore; `--clean --if-exists` makes the command safe to rerun after a partial restore. The app re-creates its grants for `sparkyfitness_app` on startup.

3. Compare row counts for every table in all three schemas, and the RLS inventory. The two outputs must be identical:
   ```fish
   set Q "select table_schema||'.'||table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema in ('public','auth','system') and table_type='BASE TABLE' order by 1"
   set R "select count(*) filter (where rowsecurity), count(*), (select count(*) from pg_policies) from pg_tables where schemaname in ('public','auth','system')"
   kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -d sparkyfitness -tAc "$Q; $R" > /tmp/old-sparky.txt
   kubectl exec -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW psql -h postgres-rw -U sparkyfitness_admin -d sparkyfitness -tAc "$Q; $R" > /tmp/new-sparky.txt
   diff /tmp/old-sparky.txt /tmp/new-sparky.txt; and echo identical
   ```
   The last line should read `96|113|177`.

4. Merge the cutover commit, push, reconcile while the HelmRelease is still suspended, and check the secret before resuming:
   ```fish
   just kube reconcile
   kubectl get secret -n selfhosted sparkyfitness-secret -o json | jq -r '.data | keys[]' | rg DB_
   flux resume helmrelease sparkyfitness -n selfhosted
   kubectl rollout status deploy/sparkyfitness-server -n selfhosted
   ```
   `SPARKY_FITNESS_DB_HOST` and the app credentials must be listed before you resume.

5. Verify, with RLS in mind: sign in, open the diary, add and edit a food entry and a measurement, open the reports and settings pages, and sign in as a second user if you have one to confirm each sees only their own data. Check the server log for `permission denied` or `row-level security` errors:
   ```fish
   kubectl logs -n selfhosted deploy/sparkyfitness-server --tail=200 | rg -i "permission denied|row-level|42501|error"
   kubectl exec -n dbms postgres-1 -c postgres -- psql -tAc "select usename, state, count(*) from pg_stat_activity where datname='sparkyfitness' group by 1,2"
   ```
   Connections should appear as both `sparkyfitness_admin` and `sparkyfitness_app`, and none on `sparkyfitness-db`.

6. Run the dump job once and confirm the `sparkyfitness` dump is complete (the BYPASSRLS check):
   ```fish
   kubectl create job -n dbms --from=cronjob/postgres-backup postgres-backup-sparky
   kubectl logs -n dbms job/postgres-backup-sparky | rg -i "sparkyfitness|error"
   ```

## Rollback

Revert the cutover commit and push. Suspend the HelmRelease and scale the server to 0 first, then resume. The old cluster is untouched until cleanup. Anything written on the shared cluster after the cutover is lost.

## Cleanup (a few days later)

1. In `apps/selfhosted/sparkyfitness/ks.yaml`, remove `components/postgres`, `healthCheckExprs`, the `cnpg-barman-cloud` dependency, `PG_BACKUP_MINUTE` and `PG_SUPERUSER`. Remove the CronJob patch from `app/kustomization.yaml`. Pruning deletes the old cluster and its volumes.
2. The old Barman archive under `s3://cnpg-6u9f/sparkyfitness/` and the NFS dumps remain until you remove them.
