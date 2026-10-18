# postgres (shared CNPG cluster)

One 2-instance CloudNativePG cluster, `postgres`, in `dbms` for apps that do not need superuser or a custom extension set. Reads and writes go to `postgres-rw.dbms.svc.cluster.local`. It is separate from the per-app `components/postgres` clusters.

Backups: Barman plugin to R2 (`serverName: postgres`, daily base backup at 11:50 UTC, continuous WAL) and a 12-hourly logical dump to NFS by the `backup` role.

Not hosted here: sparkyfitness (superuser) and tracearr (TimescaleDB).

## Isolation

1. **Network** - each tenant's `CiliumNetworkPolicy` lists the pods allowed to reach port 5432. Match by namespace and `app.kubernetes.io/name`; never by namespace alone.
2. **Authentication** - `pg_hba` in `cluster.yaml` is an allow-list ending in `host all all all reject`. A role can connect only to the database named in its rule. `enableSuperuserAccess` is off.
3. **Authorization** - each database is owned by its app role. Roles carry a `connectionLimit`.
4. **Credentials** - each app has its own password; the app namespace never gets another app's secret.

## Adding a tenant

A tenant's manifests live next to its app, in `<app>/database/`, deployed by a second Flux Kustomization `<app>-postgres` with `targetNamespace: dbms` (CNPG resources must share the cluster's namespace). See `apps/security/pocket-id/database` for the pattern.

1. In `<app>/database/`: a `Database` (owner, extensions), a `DatabaseRole` (`login: true`, `connectionLimit`, `passwordSecret`), an ExternalSecret for the role password that reads only the password property of the app's Bitwarden item, and a `CiliumNetworkPolicy` allowing the app's pods on 5432.
2. In the app's own namespace: an ExternalSecret exposing the connection details from the same Bitwarden item. The app Kustomization `dependsOn` `<app>-postgres`.
3. Here in `cluster.yaml`: a `pg_hba` line **above** the final reject, `host <database> <role> all scram-sha-256`.
4. Here in `backup.cronjob.yaml`: append the database to `POSTGRES_DB`.
5. If the app namespace has an ingress baseline, add a rule for replies from the `postgres` pods, as with `teslamate-mqtt-replies`.

## Verifying isolation

From a client pod, each of these must fail:

- connect to another app's database with this app's credentials (`pg_hba` reject)
- connect to port 5432 from a pod not listed in `networkpolicy.yaml`
- `SELECT * FROM pg_authid` as the app role

## Restore

Per-database restore is a point-in-time clone of the whole cluster followed by `pg_dump` of the one database. The `postgres-backup` dumps on NFS cover a simple logical restore.
