#!/bin/bash
set -euo pipefail

DATASET="alaafin/k8s"
SNAPSHOT_NAME="rclone-kopiur-backup-$(date +%Y%m%d-%H%M%S)"
SUBDIR_TO_SYNC="kopiur"
RCLONE_REMOTE="cloudflare-r2:kopiur-2g8x"
LOGFILE="/var/log/kopiur-r2-backup.log"
TEXTFILE_DIR="/mnt/user/appdata/scripts/node-exporter/textfile"   # node-exporter --collector.textfile.directory

# Proportional delete guard: allow up to 1/DELETE_DIVISOR of the source file count, never below the floor.
DELETE_DIVISOR=5        # 5 = 20%
MAX_DELETE_FLOOR=500

# Runs on the NAS (unRAID User Scripts), not in the cluster. See docs/notes/rclone.md.
# Usage: DRY_RUN=1 ./kopiur-r2-backup.sh   (compares only, changes nothing, no metrics written)
DRY_RUN="${DRY_RUN:-0}"

exec 9>/var/run/kopiur-r2-backup.lock
flock -n 9 || { echo "Another run in progress; exiting."; exit 0; }

MOUNTPOINT=$(zfs get -H -o value mountpoint "$DATASET")
SNAPSHOT_PATH="$MOUNTPOINT/.zfs/snapshot/$SNAPSHOT_NAME"
SRC="$SNAPSHOT_PATH/$SUBDIR_TO_SYNC"

# Atomic write of a node-exporter textfile metric (name.prom) from the given content.
write_prom() {
  local name="$1" content="$2" tmp
  [ -d "$TEXTFILE_DIR" ] || return 0
  tmp="$(mktemp "$TEXTFILE_DIR/.${name}.XXXXXX")" || return 0
  printf '%s\n' "$content" > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$TEXTFILE_DIR/${name}.prom"
}

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAILED (exit $rc); last rclone log lines:"
    tail -n 30 "$LOGFILE" 2>/dev/null || true
  fi
  # Exit code on every run (0 on success) so an alert can tell "guard tripped (7)" from "never ran".
  if [ "$DRY_RUN" != "1" ]; then
    write_prom rclone_r2_exit "# TYPE rclone_r2_last_exit_code gauge
rclone_r2_last_exit_code $rc" || true
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
[ -f "$SRC/kopia.repository.f" ] || { echo "FATAL: $SRC is not a Kopia repository, refusing to sync"; exit 1; }

# Scale the delete cap with repository size so big Kopia maintenance GCs don't trip it,
# while a mass deletion relative to repo size still aborts the run.
SRC_COUNT=$(find "$SRC" -type f | wc -l)
MAX_DELETE=$(( SRC_COUNT / DELETE_DIVISOR ))
[ "$MAX_DELETE" -lt "$MAX_DELETE_FLOOR" ] && MAX_DELETE=$MAX_DELETE_FLOOR
echo "Source files: $SRC_COUNT, max-delete: $MAX_DELETE"

OPTS=(
  --fast-list
  --transfers=16 --checkers=16
  --s3-chunk-size=32M --s3-upload-concurrency=4
  --s3-no-check-bucket
  --retries=5 --low-level-retries=20
  --stats=1m --stats-one-line
  --log-file="$LOGFILE" --log-level INFO
)
[ "$DRY_RUN" = "1" ] && OPTS+=(--dry-run)

# Pass 1: additive only. New pack files land before anything is removed.
rclone copy "$SRC" "$RCLONE_REMOTE" "${OPTS[@]}"

# Pass 2: reconcile deletions. Exceeding --max-delete aborts the run (non-zero exit, no heartbeat).
rclone sync "$SRC" "$RCLONE_REMOTE" "${OPTS[@]}" --delete-after --max-delete="$MAX_DELETE"

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run finished; see $LOGFILE (grep -c 'Skipped delete' / 'Skipped copy')"
  exit 0
fi

# Heartbeat for monitoring, only reached if both passes exit 0 (set -e).
write_prom rclone_r2 "# TYPE rclone_r2_last_success_timestamp_seconds gauge
rclone_r2_last_success_timestamp_seconds $(date +%s)"

# End-state check, independent of rclone's own accounting: after a clean sync the bucket must hold exactly the
# source files. A non-zero extra count means deletions are not reaching R2 (see OffsiteBackupDrift).
if REMOTE_COUNT=$(rclone lsf -R --files-only --fast-list --s3-no-check-bucket "$RCLONE_REMOTE" | wc -l); then
  write_prom rclone_r2_drift "# TYPE rclone_r2_source_objects gauge
rclone_r2_source_objects $SRC_COUNT
# TYPE rclone_r2_remote_extra_objects gauge
rclone_r2_remote_extra_objects $(( REMOTE_COUNT - SRC_COUNT ))"
else
  echo "WARN: could not list $RCLONE_REMOTE for the drift metric"
fi

echo "Backup completed successfully"
