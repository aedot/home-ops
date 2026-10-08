# postgres component

Reusable Kustomize component that provisions a dedicated per-app CloudNativePG (CNPG) cluster with Barman WAL archiving to Cloudflare R2, scheduled backups, network policies and local logical-dump jobs.

## What it creates

| Resource | Name | Description |
|---|---|---|
| `Cluster` | `${APP}-db` | CNPG cluster, `PG_INSTANCES` instances (default 3), PostgreSQL image pinned in `cluster.yaml` |
| `ObjectStore` | `cloudflare-r2` | Barman destination `s3://cnpg-6u9f`, 7 day retention, bzip2 compression |
| `ExternalSecret` | `${APP}-postgres` | R2 credentials for WAL archiving (from the Bitwarden item `cloudflare`) |
| `ScheduledBackup` | `${APP}-db-daily` | Daily base backup at 11:`PG_BACKUP_MINUTE` UTC |
| `NetworkPolicy` | `${APP}-db-allow-*` | Ingress only from the app's namespace, the CNPG operator, Prometheus, CoreDNS and the cluster's own pods |
| `CronJob` | `${APP}-postgres-backup` | Logical dump to NFS every 12h, minute `PG_BACKUP_MINUTE` |
| `CronJob` | `${APP}-postgres-restore` | Suspended restore job (manual trigger only; currently not included in `kustomization.yaml`) |

CNPG creates the secret `${APP}-db-app` in the app namespace with `host`, `port`, `username`, `password`, `dbname`, `uri`, `fqdn-uri`, `jdbc-uri` and `pgpass`. The read-write service is `${APP}-db-rw`. There is no pooler.

## Usage

### 1. Add the component to the app's Flux Kustomization

```yaml
# kubernetes/apps/<namespace>/<app>/ks.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  labels:
    components.postgres/cnpg: init   # NEW database only; omit when recovering from a Barman backup
spec:
  components:
    - ../../../../components/postgres
  dependsOn:
    - name: cnpg-barman-cloud
      namespace: cnpg-system
  healthCheckExprs:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
  postBuild:
    substitute:
      APP: <app>
      PG_BACKUP_MINUTE: "10"   # stagger per app
```

### 2. Wire the connection into the HelmRelease

```yaml
env:
  DATABASE_URL:
    valueFrom:
      secretKeyRef:
        name: "{{ .Release.Name }}-db-app"
        key: fqdn-uri
```

For .NET or musl based images add `ndots: 1` to the pod `dnsConfig` so the FQDN URI resolves:

```yaml
defaultPodOptions:
  dnsConfig:
    options:
      - name: ndots
        value: "1"
```

## Bootstrap modes and the `init` label

By default the cluster bootstraps with `recovery` from the Barman archive (`serverName: ${APP}`). `components.postgres/cnpg: init` swaps that for `initdb` and removes `externalClusters` (patched in `kubernetes/flux/cluster/ks.yaml`).

The cluster carries `cnpg.io/skipEmptyWalArchiveCheck: enabled` so a rebuild can recover from, and then write to, the same archive path. That also disables CNPG's guard against a new cluster writing into an archive that already holds another cluster's WAL. Therefore:

- Only put the `init` label on an app that has **no** existing backups under `s3://cnpg-6u9f/<app>/`.
- No app currently carries the label. Do not leave it on an app whose cluster you may need to rebuild from backup; a rebuild with the label would start from an empty database.

## Local backup jobs

`jobs/backup.cronjob.yaml` writes gzip dumps to NFS at `yemoja.internal:/mnt/alaafin/k8s/postgres`. Failed Jobs are kept for 24h and the last three failures are retained.

```bash
# manual backup
kubectl create job -n <ns> --from=cronjob/<app>-postgres-backup <app>-backup-$(date +%s)
```

`jobs/restore.cronjob.yaml` is a suspended CronJob that restores `<dbname>-latest.sql.gz` (or `POSTGRES_RESTORE_FILE`) into an empty database. Enable it in `kustomization.yaml` when you need it, then trigger it the same way with `--from=cronjob/<app>-postgres-restore`.

## S3 backups

`ScheduledBackup` takes a daily base backup through the barman-cloud plugin; WAL is archived continuously to the same prefix. Compression and `immediateCheckpoint` are configured on the `ObjectStore`, not on the plugin parameters. Alerts: `CNPGBackupFailed`, `CNPGBackupStale`, `LastFailedArchiveTime` (see `kubernetes/apps/cnpg-system`).

## Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `APP` | yes | - | App name; used for cluster, secret and database names |
| `CLOUDFLARE_ACCOUNT_ID` | yes | - | From `cluster-secrets`; builds the R2 endpoint |
| `PG_INSTANCES` | no | `3` | Instances per cluster (anti-affinity is required, so keep it at or below the node count) |
| `PG_STORAGE_SIZE` | no | `5Gi` | PVC size per instance |
| `PG_STORAGE_CLASS` | no | `longhorn-postgres` | Single-replica Longhorn class; CNPG provides the redundancy. Only affects new PVCs |
| `PG_MEMORY_REQUEST` | no | `512Mi` | Memory request per instance |
| `PG_MEMORY_LIMIT` | no | `1Gi` | Memory limit per instance |
| `PG_BACKUP_MINUTE` | no | `0` | Minute for the daily S3 backup (11:MM UTC) and the 12-hourly dump; stagger per app |
| `PG_SUPERUSER` | no | `false` | Set `"true"` to create the `${APP}-db-superuser` secret (needed by sparkyfitness) |
