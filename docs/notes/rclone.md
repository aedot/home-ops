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

exec 9>/var/run/kopiur-r2-backup.lock
flock -n 9 || { echo "Another run in progress; exiting."; exit 0; }

MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET")
SNAPSHOT_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAPSHOT_NAME"
SRC="$SNAPSHOT_PATH/$SUBDIR_TO_SYNC"

cleanup() {
  if zfs list -H -t snapshot "$DATASET@$SNAPSHOT_NAME" >/dev/null 2>&1; then
    echo "Destroying snapshot $DATASET@$SNAPSHOT_NAME"
    zfs destroy "$DATASET@$SNAPSHOT_NAME" || echo "WARN: snapshot destroy failed"
  fi
}
trap cleanup EXIT INT TERM

echo "Creating snapshot $DATASET@$SNAPSHOT_NAME"
zfs snapshot "$DATASET@$SNAPSHOT_NAME"

ls "$SNAPSHOT_PATH" >/dev/null 2>&1 || true   # trigger automount
[ -d "$SRC" ] || { echo "FATAL: $SRC missing"; exit 1; }
[ -n "$(ls -A "$SRC")" ] || { echo "FATAL: source empty, refusing to sync"; exit 1; }

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

# Pass 2: reconcile deletions.
rclone sync "$SRC" "$RCLONE_REMOTE" "${OPTS[@]}" --delete-after

echo "Backup completed successfully"
```

This script will grab a ZFS snapshot, rclone sync that to the remote bucket, and then destroy the snapshot. This ensures the data isn't written to mid-flight. It will also delete any removed files in the meantime.
