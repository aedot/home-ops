# postgres (shared CNPG cluster)

One 3-instance CloudNativePG cluster, `postgres`, in `dbms` for apps that do not need superuser or a custom extension set. Reads and writes go to `postgres-rw.dbms.svc.cluster.local`. It is separate from the per-app `components/postgres` clusters.

Backups: Barman plugin to R2 (`serverName: postgres`, daily base backup at 11:50 UTC, continuous WAL) and a 12-hourly logical dump to NFS by the `backup` role.

Not hosted here: sparkyfitness (superuser) and tracearr (TimescaleDB).

## Isolation

1. **Network** - `networkpolicy.yaml` lists the pods allowed to reach port 5432. Match by namespace and `app.kubernetes.io/name`; never by namespace alone.
2. **Authentication** - `pg_hba` in `cluster.yaml` is an allow-list ending in `host all all all reject`. A role can connect only to the database named in its rule. `enableSuperuserAccess` is off.
3. **Authorization** - each database is owned by its app role. Roles carry a `connectionLimit`.
4. **Credentials** - each app has its own password; the app namespace never gets another app's secret.

## Adding a tenant

All of these live in `dbms`, because CNPG resources must share the cluster's namespace.

1. `Database` (owner, extensions) and `DatabaseRole` (`login: true`, `connectionLimit`, `passwordSecret`) for the app.
2. An ExternalSecret in `dbms` (`kubernetes.io/basic-auth`, keys `username` and `password`) for the role, and one in the app namespace exposing `host`, `port`, `username`, `password`, `dbname` and `uri`. Both read the same Bitwarden item.
3. A `pg_hba` line **above** the final reject: `host <database> <role> all scram-sha-256`.
4. A client rule in `networkpolicy.yaml` for the app's pods. The app namespace may also need an ingress rule for replies from the `postgres` pods, as with `teslamate-mqtt-replies`.
5. Append the database to `POSTGRES_DB` in `backup.cronjob.yaml`.

## Verifying isolation

From a client pod, each of these must fail:

- connect to another app's database with this app's credentials (`pg_hba` reject)
- connect to port 5432 from a pod not listed in `networkpolicy.yaml`
- `SELECT * FROM pg_authid` as the app role

## Restore

Per-database restore is a point-in-time clone of the whole cluster followed by `pg_dump` of the one database. The `postgres-backup` dumps on NFS cover a simple logical restore.
