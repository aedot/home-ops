# Rclone to R2

## Install and setup rclone
Install rclone on your NAS

Run the rclone config for the endpoint

```sh
rclone config
```

1) Select n for a new remote.

2) Enter a name (e.g., cloudflare-r2).

3) Choose s3 as the storage type.

4) Set S3 provider to Cloudflare (option 6).

5) Enter the Cloudflare R2 Access Key and Secret Key (found in your Cloudflare dashboard under "R2 API Tokens"). Note that you want to scope this to read/write on a specific bucket(s).

6) Set endpoint to your Cloudflare R2 bucket’s region:

```sh
https://<account-id>.r2.cloudflarestorage.com
```

7) Leave region blank.

8) Use default options for remaining settings.

9) Test the connection by running:
```sh
rclone ls cloudflare-r2:<bucketname>
```
## Create script

Create the script and save it somewhere notable (or for unRaid, use User Scripts plugin)

```sh
#!/bin/bash
set -euo pipefail

DATASET="alaafin/k8s"
SNAPSHOT_NAME="rclone-kopiur-backup-$(date +%Y%m%d-%H%M%S)"
SUBDIR_TO_SYNC="kopiur"
RCLONE_REMOTE="cloudflare-r2:kopiur-2g8x"
LOGFILE="/var/log/kopiur-r2-backup.log"
TEXTFILE_DIR="/mnt/user/appdata/scripts/node-exporter/textfile"   # node-exporter --collector.textfile.directory
MAX_DELETE=500   # above the most files Kopia maintenance removes in one run; tune from "Deleted:" counts in the log

exec 9>/var/run/kopiur-r2-backup.lock
flock -n 9 || { echo "Another run in progress; exiting."; exit 0; }

MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET")
SNAPSHOT_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAPSHOT_NAME"
SRC="$SNAPSHOT_PATH/$SUBDIR_TO_SYNC"

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAILED (exit $rc); last rclone log lines:"
    tail -n 30 "$LOGFILE" 2>/dev/null || true
  fi
  if zfs list -H -t snapshot "$DATASET@$SNAPSHOT_NAME" >/dev/null 2>&1; then
    echo "Destroying snapshot $DATASET@$SNAPSHOT_NAME"
    zfs destroy "$DATASET@$SNAPSHOT_NAME" || echo "WARN: snapshot destroy failed"
  fi
}
# INT/TERM must exit; a bare trap handler would let the script continue with the snapshot gone.
trap cleanup EXIT
trap 'exit 143' INT TERM

# Snapshots leaked by a killed or crashed earlier run; the lock above guarantees none is in use.
zfs list -H -t snapshot -o name -d 1 "$DATASET" | { grep "^$DATASET@rclone-kopiur-backup-" || true; } |
  while read -r stale; do
    zfs destroy "$stale" || echo "WARN: could not destroy stale snapshot $stale"
  done

: > "$LOGFILE"   # /var/log is tmpfs on unRaid; keep only the current run

echo "Creating snapshot $DATASET@$SNAPSHOT_NAME"
zfs snapshot "$DATASET@$SNAPSHOT_NAME"

ls "$SNAPSHOT_PATH" >/dev/null 2>&1 || true   # trigger automount
[ -d "$SRC" ] || { echo "FATAL: $SRC missing"; exit 1; }
[ -n "$(ls -A "$SRC")" ] || { echo "FATAL: source empty, refusing to sync"; exit 1; }
[ -f "$SRC/kopia.repository" ] || { echo "FATAL: $SRC is not a Kopia repository, refusing to sync"; exit 1; }

OPTS=(
  --fast-list
  --transfers=16 --checkers=16
  --s3-chunk-size=32M --s3-upload-concurrency=4
  --s3-no-check-bucket
  --retries=5 --low-level-retries=20
  --stats=1m --stats-one-line
  --log-file="$LOGFILE" --log-level INFO
)

# Pass 1: additive only. New pack files land before anything is removed.
rclone copy "$SRC" "$RCLONE_REMOTE" "${OPTS[@]}"

# Pass 2: reconcile deletions. Exceeding --max-delete aborts the run (non-zero exit, no heartbeat).
rclone sync "$SRC" "$RCLONE_REMOTE" "${OPTS[@]}" --delete-after --max-delete="$MAX_DELETE"

# Heartbeat for monitoring, only reached if both passes exit 0 (set -e).
tmp="$(mktemp "$TEXTFILE_DIR/.rclone_r2.XXXXXX")"
printf '# TYPE rclone_r2_last_success_timestamp_seconds gauge\nrclone_r2_last_success_timestamp_seconds %s\n' "$(date +%s)" > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$TEXTFILE_DIR/rclone_r2.prom"

echo "Backup completed successfully"
```

This script will grab a ZFS snapshot, rclone sync that to the remote bucket, and then destroy the snapshot. This ensures the data isn't written to mid-flight. It will also delete any removed files in the meantime.

## Heartbeat for monitoring

The cluster scrapes the NAS node-exporter (`yemoja.internal:9100`). The script above writes a timestamp after each
successful upload so `OffsiteBackupStale` (36h) and `OffsiteBackupMetricMissing` (12h) in
`kubernetes/apps/observability/kube-prometheus-stack/app/prometheusrule.yaml` can fire when it stops.
Adjust the 36h threshold if the script runs less often than daily.

node-exporter only serves the file if it is started with the textfile directory flag, which is off by default:

```sh
prometheus_node_exporter --collector.textfile.directory=/mnt/user/appdata/scripts/node-exporter/textfile
```

`TEXTFILE_DIR` in the script must match that path. The flag must also be set in whatever starts node-exporter at
boot, or the metric disappears after a reboot. Verify with:

```sh
curl -s localhost:9100/metrics | grep -E 'node_textfile_scrape_error|rclone_r2'
```

The "There was nothing to transfer" line at the end of the rclone log is normal: it comes from the `sync` pass,
which has nothing left to do after the `copy` pass.
