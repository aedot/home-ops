# grampsweb: dedicated cluster to the shared Postgres cluster

One-off migration runbook. Commands are fish. Grampsweb already runs on Postgres (`grampsweb-db`), so this is a database move.

## Where the connection lives

Two places must change, and both must change before the app starts:

1. **Environment** (GitOps): `GRAMPSWEB_POSTGRES_HOST/PORT/USER/PASSWORD` and the two `*_DB_URI` values. The cutover commit moves them from the `grampsweb-db-app` secret into `grampsweb-secret`.
2. **`settings.ini` on the PVC**: `/root/.gramps/grampsdb/<tree-id>/settings.ini` hardcodes `host='grampsweb-db-rw'` and `dbname='gramps'`. The short host name only resolves inside `selfhosted`, so it is rewritten to the shared cluster's FQDN.

Two databases move: `gramps` (tree data) and `grampsweb` (user accounts and search index). Both are owned by role `grampsweb`.

## Stages

1. **Stage 1** (tenant): databases, role, ExternalSecret, client and reply network policies, the `pg_hba` lines and the dump entries. Safe to merge on its own.
2. **Data move and cutover**: below.
3. **Stage 3** (cleanup, a few days later): drop the postgres component and the old `app/database.yaml`.

## Prerequisites

1. The `grampsweb` Bitwarden item has `POSTGRES_PASSWORD` (letters and digits only).
2. Stage 1 is on `main` and applied:
   ```fish
   kubectl get externalsecret,databaserole,database -n dbms | rg grampsweb
   ```
   Everything must be synced and `APPLIED: true`. A "secrets is forbidden" message on the role clears by itself after a minute.

## Steps

1. Take a baseline and stop the app so nothing writes during the copy:
   ```fish
   flux suspend helmrelease grampsweb -n selfhosted
   kubectl scale deploy/grampsweb -n selfhosted --replicas=0
   ```

2. Copy both databases (small; streamed through your machine):
   ```fish
   set PW (kubectl get secret -n dbms postgres-grampsweb-secret -o jsonpath='{.data.password}' | base64 -d)
   set PRIMARY (kubectl get cluster.postgresql.cnpg.io -n selfhosted grampsweb-db -o jsonpath='{.status.currentPrimary}')
   for db in gramps grampsweb
       kubectl exec -n selfhosted $PRIMARY -c postgres -- pg_dump -Fc -d $db | kubectl exec -i -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW pg_restore -h postgres-rw -U grampsweb -d $db --no-owner --exit-on-error
   end
   ```

3. Compare row counts for every table in both databases. The two outputs must be identical:
   ```fish
   set Q "select table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"
   for db in gramps grampsweb
       kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -d $db -tAc "$Q" > /tmp/old-$db.txt
       kubectl exec -n dbms postgres-1 -c postgres -- env PGPASSWORD=$PW psql -h postgres-rw -U grampsweb -d $db -tAc "$Q" > /tmp/new-$db.txt
       diff /tmp/old-$db.txt /tmp/new-$db.txt; and echo "$db: identical"
   end
   ```

4. Point `settings.ini` at the shared cluster with a one-off pod built from the live Deployment (same image, PVC and subPath mounts). It backs the file up first:
   ```fish
   set T 2fff588f-1d54-471d-b665-5986760e6b1c
   set CMD "cd /root/.gramps/grampsdb/$T && cp settings.ini settings.ini.bak && sed -i \"s|^host=.*|host='postgres-rw.dbms.svc.cluster.local'|\" settings.ini && grep -c postgres-rw.dbms settings.ini"
   kubectl get deploy -n selfhosted grampsweb -o json | jq --arg cmd "$CMD" '{apiVersion:"v1",kind:"Pod",metadata:{name:"grampsweb-fix-host",namespace:"selfhosted",labels:.spec.template.metadata.labels},spec:(.spec.template.spec | .restartPolicy="Never" | .containers=[.containers[0]] | .containers[0] |= (.command=["sh","-c",$cmd] | .args=[] | del(.livenessProbe,.readinessProbe,.startupProbe)))}' | kubectl create -f -
   kubectl wait -n selfhosted pod/grampsweb-fix-host --for=jsonpath='{.status.phase}'=Succeeded --timeout=240s
   kubectl logs -n selfhosted grampsweb-fix-host
   ```
   The log must print `1`. The pod can sit in `ContainerCreating` for a minute while Longhorn detaches the volume from the old pod. Then `kubectl delete pod -n selfhosted grampsweb-fix-host`.

5. Merge the cutover commit, push, reconcile while the HelmRelease is still suspended, then resume:
   ```fish
   just kube reconcile
   flux resume helmrelease grampsweb -n selfhosted
   kubectl rollout status deploy/grampsweb -n selfhosted
   ```

6. Verify: sign in at the Gramps URL, open the tree, edit and save a person, run a search. Confirm traffic on the shared cluster and none on the old one:
   ```fish
   kubectl exec -n dbms postgres-1 -c postgres -- psql -tAc "select datname, usename, state, count(*) from pg_stat_activity where usename='grampsweb' group by 1,2,3"
   kubectl exec -n selfhosted $PRIMARY -c postgres -- psql -tAc "select datname, usename, state, count(*) from pg_stat_activity where usename='grampsweb' group by 1,2,3"
   ```
   The second query should return nothing.

## Rollback

Revert the cutover commit and push. Suspend the HelmRelease and scale to 0 first. Rerun step 4's pod with `cp settings.ini.bak settings.ini` as the command, then resume. The old cluster is untouched until cleanup. Changes made on the shared cluster after the cutover are lost.

## Cleanup (a few days later)

1. In `apps/selfhosted/grampsweb/ks.yaml`, remove `components/postgres`, `healthCheckExprs`, the `cnpg-barman-cloud` dependency and `PG_BACKUP_MINUTE`; remove `app/database.yaml` and its entry in `app/kustomization.yaml`. Pruning deletes the old cluster and its volumes.
2. Delete `settings.ini.bak` from the PVC.
3. The old Barman archive under `s3://cnpg-6u9f/grampsweb/` and the NFS dumps remain until you remove them.
