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

The script lives in the repo at [`scripts/kopiur-r2-backup.sh`](../../scripts/kopiur-r2-backup.sh) so it is linted
(`shellcheck` runs on `scripts/*.sh` in the pre-commit hook). Copy it to the NAS as the User Script and `diff` the
two after any edit; the repo copy is the source of truth.

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

The script writes three groups of textfile metrics, used by the rules in the same `prometheusrule.yaml`:

- `rclone_r2_last_success_timestamp_seconds` (`rclone_r2.prom`): only after a clean run. `OffsiteBackupStale`.
- `rclone_r2_last_exit_code` (`rclone_r2_exit.prom`): every run; 0 on success, 7 when the `--max-delete` guard or
  another rclone fatal error aborted the sync. `OffsiteBackupFailed`.
- `rclone_r2_source_objects` and `rclone_r2_remote_extra_objects` (`rclone_r2_drift.prom`): after a clean run, the
  bucket's object count minus the source's. It should be 0; a persistent surplus means deletions are not reaching
  R2. `OffsiteBackupDrift`. It is only refreshed on a clean run, so a run that aborts leaves the previous value.

`DRY_RUN=1` compares only and writes no metrics; it cannot catch R2 permission errors because a dry run never
attempts the writes.

The "There was nothing to transfer" line at the end of the rclone log is normal: it comes from the `sync` pass,
which has nothing left to do after the `copy` pass.
