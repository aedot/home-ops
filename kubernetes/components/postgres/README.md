# postgres component

Reusable Kustomize component that provisions a dedicated per-app CloudNativePG (CNPG) cluster with Barman WAL archiving to Cloudflare R2, scheduled backups, and optional local dump backup/restore jobs.

## What it creates

| Resource | Name | Description |
|---|---|---|
| `Cluster` | `${APP}-db` | 3-instance CNPG cluster (PG 18) |
| `ExternalSecret` | `${APP}-postgres` | R2 credentials for WAL archiving |
| `ScheduledBackup` | `${APP}-db-daily` | Daily base backup at 11:`PG_BACKUP_MINUTE` UTC |
| `NetworkPolicy` | `${APP}-db-allow-*` | Ingress to the cluster only from its namespace, the CNPG operator and Prometheus |
| `CronJob` | `${APP}-postgres-backup` | Local dump to NFS every 12h |
| `CronJob` | `${APP}-postgres-restore` | Suspended restore job (manual trigger only) |

CNPG also auto-creates a secret `${APP}-psql-app` in the app namespace with connection fields: `host`, `port`, `username`, `password`, `dbname`, `uri`, `fqdn-uri`.

## Usage

### 1. Add the component to your app's Kustomization

```yaml
# kubernetes/apps/<namespace>/<app>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  labels:
    components.postgres/cnpg: init   # NEW cluster — omit if restoring from Barman backup
spec:
  components:
    - ../../../../components/postgres
  healthCheckExprs:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
  postBuild:
    substitute:
      APP: <app>
```

> **`components.postgres/cnpg: init` label** — add this for brand-new clusters with no existing Barman backup. It patches the bootstrap to use `initdb` instead of the default `recovery` mode. Omit it when you have a prior backup to restore from.

### 2. Wire the DB connection in your HelmRelease

Reference the CNPG-generated secret directly — no SecretStore or ESO templating needed:

```yaml
env:
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: <app>-psql-app
        key: fqdn-uri          # full FQDN URI: postgresql://user:pass@<app>-psql-rw.<ns>.svc.cluster.local:5432/<db>
```

Other available keys from `<app>-db-app`: `host`, `port`, `username`, `password`, `dbname`, `uri`, `pgpass`.

> **DNS note** — add `ndots: 1` to your pod's `dnsConfig` to avoid `.NET` / musl DNS resolution issues with `fqdn-uri`:
> ```yaml
> defaultPodOptions:
>   dnsConfig:
>     options:
>       - name: ndots
>         value: "1"
> ```

### 3. Remove old patterns

When migrating from the shared `pgsql-cluster`:
- Remove `initContainers.init-db` (postgres-init container) from the HelmRelease
- Remove `cnpg-cluster` from `dependsOn`
- Remove `CNPG_NAME` and `cnpg-users` references from the ExternalSecret
- Drop `components/cnpg` in favour of `components/postgres`

## Migrating data from the old shared cluster

If the app previously ran on `pgsql-cluster` you need to restore its database into the new per-app cluster.

### Step 1 — Spin up a temporary restore cluster

```bash
# Apply the restore cluster (adjust backupID to a known-good backup)
kubectl apply -f kubernetes/apps/dbms/cnpg/cluster/cluster17-restore.yaml -n dbms
kubectl get cluster -n dbms pgsql-cluster-restore -w
```

### Step 2 — Dump the database

```bash
kubectl exec -i -n dbms pgsql-cluster-restore-1 -- pg_dump -U postgres <app> > <app>.dump
```

### Step 3 — Restore into the new cluster

```bash
# Drop the app-migration-created schema and restore from dump
kubectl exec -n <ns> <app>-psql-1 -- psql -U postgres -c "DROP DATABASE <app>; CREATE DATABASE <app>;"
kubectl exec -i -n <ns> <app>-psql-1 -- psql -U postgres <app> -v ON_ERROR_STOP=1 < <app>.dump

# Verify
kubectl exec -n <ns> <app>-psql-1 -- psql -U postgres <app> -c "\dt"
```

### Step 4 — Clean up

```bash
kubectl delete cluster -n dbms pgsql-cluster-restore
rm <app>.dump
```

## Local backup jobs

The `jobs/backup.cronjob.yaml` and `jobs/restore.cronjob.yaml` are included in the component and run in the app's namespace. Backups are written to NFS at `yemoja.internal:/mnt/alaafin/k8s/postgres`.

**Trigger a manual backup:**
```bash
kubectl create job -n <ns> --from=cronjob/<app>-postgres-backup <app>-backup-$(date +%s)
```

**Trigger a manual restore** (restore job is suspended by default):
```bash
kubectl create job -n <ns> --from=cronjob/<app>-postgres-restore <app>-restore-$(date +%s)
```

To restore a specific file, set `POSTGRES_RESTORE_FILE` in the restore CronJob before triggering.

## S3 Backup

Daily full backups via the `ScheduledBackup` resource (03:00, see `scheduledbackup.yaml`). Continuous WAL archiving to the same `s3://postgresql/${APP}/` prefix. `retentionPolicy: 7d`.

## Connecting from an app

CNPG generates a `${APP}-app` Secret with these keys: `uri`, `jdbc-uri`, `username`, `password`, `host`, `port`, `dbname`, `pgpass`.

Standard app-template pattern:

```yaml
DATABASE_URL:
    valueFrom:
        secretKeyRef:
            name: "{{ .Release.Name }}-app"
            key: uri
```

The `uri` points at the cluster's read-write primary service `${APP}-rw`. There is no `Pooler` / PgBouncer in this component — apps connect directly. If transaction-mode pooling is ever needed (e.g. authentik at scale), add a `Pooler` CRD per cluster as a follow-up.


## Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `APP` | ✅ | — | App name — used for cluster, secret, and DB names |
| `PG_VER` | ❌ | `18` | PostgreSQL major version for local backup image |
| `CLOUDFLARE_ACCOUNT_ID` | ✅ | — | From `cluster-secrets` — R2 endpoint |
| `PG_INSTANCES` | ❌ | `3` | Instances per cluster (anti-affinity is required, so keep it at or below the node count) |
| `PG_STORAGE_SIZE` | ❌ | `5Gi` | PVC size per instance |
| `PG_STORAGE_CLASS` | ❌ | `longhorn-postgres` | Single-replica Longhorn class; CNPG provides the redundancy. Only affects newly created PVCs |
| `PG_MEMORY_REQUEST` | ❌ | `512Mi` | Memory request per instance |
| `PG_MEMORY_LIMIT` | ❌ | `1Gi` | Memory limit per instance |
| `PG_BACKUP_MINUTE` | ❌ | `0` | Minute of the daily 11:00 UTC backup; stagger per app |
