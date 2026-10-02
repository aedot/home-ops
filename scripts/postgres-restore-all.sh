#!/usr/bin/env bash
#
# postgres-restore-all.sh — reconcile + re-seed the CNPG postgres apps from
# their NFS logical dumps after the switch to empty (initdb) bootstrap.
#
# For each app WITH a dump it:
#   1. reconciles the Flux Kustomization (pulls the merged initdb override),
#   2. deletes the existing Cluster so CNPG re-bootstraps it EMPTY,
#      (CNPG will not re-bootstrap a Cluster that already exists — it must be
#       recreated for initdb to take effect; this also removes its PVCs),
#   3. waits for the fresh empty Cluster to become Ready,
#   4. QUIESCES the app (suspends its Flux Kustomization + HelmRelease and scales
#      the workload to 0) so it can't (re)create its own schema mid-restore,
#   5. RESETS the database (drops all user schemas) — apps self-migrate their
#      schema on boot, which collides with the dump's CREATE SCHEMA,
#   6. triggers the <app>-postgres-restore Job and follows it to completion,
#   7. scales the app back and resumes Flux.
# Apps with no dump (tracearr) are skipped and left app-initialized.
#
# DESTRUCTIVE: step 2 deletes each Cluster and its data volumes, and step 5
# drops all user schemas. Requires a confirmation per app unless --yes is
# passed. Use --dry-run to preview.
#
# Usage:
#   ./postgres-restore-all.sh [--yes] [--dry-run] [--apps "lubelog teslamate"]
#
# Flags:
#   --yes          skip the per-app "delete cluster?" confirmation
#   --dry-run      print the commands without running the mutating ones
#   --apps "a b c" restrict to a subset (default: all six)
#
set -uo pipefail

# ---- app -> namespace, and whether an NFS dump exists to restore from --------
# has_dump=no  -> cluster is bootstrapped empty and the restore is a no-op
#                 (the Job will fail to find a file); harmless, app self-inits.
declare -A NS=(
  [baby-tracker]=selfhosted
  [lubelog]=selfhosted
  [sparkyfitness]=selfhosted
  [teslamate]=selfhosted
  [tracearr]=media
)
declare -A HAS_DUMP=(
  [baby-tracker]=yes
  [lubelog]=yes
  [sparkyfitness]=yes
  [teslamate]=yes
  [tracearr]=no      # no dump on the NFS share — comes up empty
)

FLUX_NS="${FLUX_NS:-}"   # override the Flux Kustomization namespace; empty = use
                         # each app's own namespace (these CRs are stamped into
                         # apps/<ns>/kustomization.yaml -> namespace: <ns>)
CLUSTER_READY_TIMEOUT="${CLUSTER_READY_TIMEOUT:-600}"   # seconds
RESTORE_TIMEOUT="${RESTORE_TIMEOUT:-3600}"              # seconds (teslamate is big)

APPS="baby-tracker lubelog sparkyfitness teslamate tracearr"
ASSUME_YES=0; DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --apps) APPS="$2"; shift 2 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

run() {   # run a mutating command (respects --dry-run)
  echo "+ $*"
  [[ "$DRY_RUN" == 1 ]] && return 0
  "$@"
}

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0
  read -r -p "  → ${1}: DELETE & rebuild cluster ${1}-db in ns/${2}? (n = reset schemas in place) [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

wait_cluster_ready() {   # ns app
  local ns="$1" app="$2" deadline=$(( $(date +%s) + CLUSTER_READY_TIMEOUT ))
  echo "  waiting for ${app}-db to be Ready (timeout ${CLUSTER_READY_TIMEOUT}s)..."
  [[ "$DRY_RUN" == 1 ]] && { echo "  (dry-run: skip wait)"; return 0; }
  while :; do
    local ready phase
    ready=$(kubectl -n "$ns" get cluster "${app}-db" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "")
    phase=$(kubectl -n "$ns" get cluster "${app}-db" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${ready:-0}" -ge 1 ]]; then
      echo "  ${app}-db ready (${ready} instance(s), phase: ${phase})"
      return 0
    fi
    [[ $(date +%s) -ge $deadline ]] && { echo "  TIMEOUT waiting for ${app}-db (phase: ${phase})" >&2; return 1; }
    sleep 5
  done
}

wait_cronjob() {   # ns app  — ensure Flux has created the restore CronJob
  local ns="$1" app="$2" deadline=$(( $(date +%s) + 120 ))
  [[ "$DRY_RUN" == 1 ]] && return 0
  while ! kubectl -n "$ns" get cronjob "${app}-postgres-restore" >/dev/null 2>&1; do
    [[ $(date +%s) -ge $deadline ]] && { echo "  restore CronJob not found for ${app}" >&2; return 1; }
    sleep 3
  done
}

workload_ref() {   # ns app -> "deploy/<app>" or "statefulset/<app>" (best-effort)
  local ns="$1" app="$2"
  if kubectl -n "$ns" get deploy "$app" >/dev/null 2>&1; then echo "deploy/${app}"
  elif kubectl -n "$ns" get statefulset "$app" >/dev/null 2>&1; then echo "statefulset/${app}"
  else echo ""; fi
}

primary_pod() {    # ns app -> primary CNPG pod name
  kubectl -n "$1" get pod -l "cnpg.io/cluster=${2}-db,cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Suspend Flux for the app and scale its workload to 0, so it can't (re)create
# its own schema while we reset+restore. Records original replicas in globals.
QUIESCED_WORKLOAD=""; QUIESCED_REPLICAS=1
CUR_NS=""; CUR_APP=""; CUR_FNS=""   # for the interrupt trap
quiesce_app() {    # ns app fns
  local ns="$1" app="$2" fns="$3"
  CUR_NS="$ns"; CUR_APP="$app"; CUR_FNS="$fns"
  echo "  quiescing ${app}: suspend flux + scale workload to 0"
  run flux -n "$fns" suspend kustomization "$app" || true
  run flux -n "$ns" suspend helmrelease "$app" || true
  QUIESCED_WORKLOAD="$(workload_ref "$ns" "$app")"; QUIESCED_REPLICAS=1
  if [[ -n "$QUIESCED_WORKLOAD" ]]; then
    QUIESCED_REPLICAS="$(kubectl -n "$ns" get "$QUIESCED_WORKLOAD" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
    [[ -z "$QUIESCED_REPLICAS" ]] && QUIESCED_REPLICAS=1
    run kubectl -n "$ns" scale "$QUIESCED_WORKLOAD" --replicas=0
    [[ "$DRY_RUN" == 1 ]] || kubectl -n "$ns" rollout status "$QUIESCED_WORKLOAD" --timeout=120s 2>/dev/null || true
  else
    echo "  WARN: no deploy/statefulset named '${app}' to scale down" >&2
  fi
}

unquiesce_app() {  # ns app fns  — always call to undo quiesce_app
  local ns="$1" app="$2" fns="$3"
  echo "  restoring ${app}: scale back + resume flux"
  [[ -n "$QUIESCED_WORKLOAD" ]] && run kubectl -n "$ns" scale "$QUIESCED_WORKLOAD" --replicas="${QUIESCED_REPLICAS:-1}"
  run flux -n "$ns" resume helmrelease "$app" || true
  run flux -n "$fns" resume kustomization "$app" || true
  QUIESCED_WORKLOAD=""; QUIESCED_REPLICAS=1
}

# Drop every non-system schema so the dump restores into a pristine DB. Apps
# self-migrate their schema (e.g. lubelog creates schema "app"), which collides
# with the dump's CREATE SCHEMA; this clears it first. Runs as the in-pod
# superuser (peer auth); psql var :owner carries the app/owner name safely.
reset_db() {       # ns app
  local ns="$1" app="$2" pod; pod="$(primary_pod "$ns" "$app")"
  if [[ -z "$pod" ]]; then echo "  ERROR: no primary pod for ${app}-db" >&2; return 1; fi
  echo "  resetting database '${app}' (drop user schemas) via ${pod}"
  [[ "$DRY_RUN" == 1 ]] && { echo "  (dry-run: skip reset)"; return 0; }
  kubectl -n "$ns" exec -i "$pod" -c postgres -- \
    psql -U postgres -d "$app" -v ON_ERROR_STOP=1 -v owner="$app" <<'SQL'
DO $reset$
DECLARE r record;
BEGIN
  FOR r IN SELECT nspname FROM pg_namespace
           WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'
  LOOP EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', r.nspname); END LOOP;
END
$reset$;
CREATE SCHEMA public AUTHORIZATION :"owner";
GRANT ALL ON SCHEMA public TO :"owner";
SQL
}

do_app() {
  local app="$1" ns="${NS[$1]}" dump="${HAS_DUMP[$1]}"
  echo
  echo "=============================================================="
  echo " ${app}  (ns/${ns}, nfs-dump: ${dump})"
  echo "=============================================================="

  local fns="${FLUX_NS:-$ns}"   # Flux Kustomization lives in the app's namespace

  if [[ "$dump" == "no" ]]; then
    echo "  ${app}: no NFS dump — leaving the app-initialized empty database as-is."
    return 0
  fi

  # 1. reconcile the merged config
  run flux -n "$fns" reconcile kustomization "$app" --with-source || \
    echo "  WARN: reconcile failed/absent for ${app} (continuing)"

  # 2. get an empty initdb cluster ready. Delete+rebuild guarantees a clean
  #    initdb cluster with the right dbname; declining resets + restores in
  #    place (faster, for clusters already on initdb). The reset in step 3
  #    empties either way.
  if kubectl -n "$ns" get cluster "${app}-db" >/dev/null 2>&1; then
    if confirm "$app" "$ns"; then
      run kubectl -n "$ns" delete cluster "${app}-db" --wait=true
      run flux -n "$fns" reconcile kustomization "$app" || true   # recreate empty
    else
      echo "  keeping existing ${app}-db; will reset schemas + restore in place."
    fi
  else
    echo "  no existing ${app}-db cluster; Flux will create it fresh."
    run flux -n "$fns" reconcile kustomization "$app" || true
  fi
  wait_cluster_ready "$ns" "$app" || { echo "  ABORT ${app}: cluster not ready"; return 1; }
  wait_cronjob "$ns" "$app"       || { echo "  ABORT ${app}: no restore CronJob"; return 1; }

  # 3. quiesce the app, reset the DB, restore, then bring the app back
  quiesce_app "$ns" "$app" "$fns"
  if ! reset_db "$ns" "$app"; then
    echo "  ❌ ${app}: DB reset failed; skipping restore"
    unquiesce_app "$ns" "$app" "$fns"
    return 1
  fi

  local job="${app}-restore-$(date +%s)"
  run kubectl -n "$ns" create job --from="cronjob/${app}-postgres-restore" "$job"
  if [[ "$DRY_RUN" == 1 ]]; then unquiesce_app "$ns" "$app" "$fns"; return 0; fi

  echo "  following ${job} ..."
  kubectl -n "$ns" wait --for=condition=complete "job/${job}" --timeout="${RESTORE_TIMEOUT}s" &
  local waitpid=$!
  kubectl -n "$ns" logs -f "job/${job}" 2>/dev/null || true
  wait "$waitpid" 2>/dev/null
  if kubectl -n "$ns" get job "$job" -o jsonpath='{.status.succeeded}' | grep -q 1; then
    echo "  ✅ ${app} restore complete"
  else
    echo "  ❌ ${app} restore Job did NOT succeed — investigate: kubectl -n ${ns} logs job/${job}"
  fi

  unquiesce_app "$ns" "$app" "$fns"
}

# If interrupted mid-restore, undo the quiesce so we never leave an app
# suspended and scaled to zero.
cleanup_on_exit() {
  if [[ -n "${QUIESCED_WORKLOAD:-}" && -n "${CUR_APP:-}" ]]; then
    echo "  interrupted — bringing ${CUR_APP} back up..." >&2
    unquiesce_app "$CUR_NS" "$CUR_APP" "$CUR_FNS"
  fi
}
trap cleanup_on_exit EXIT INT TERM

echo "Apps: $APPS"
echo "Flux Kustomization namespace: ${FLUX_NS:-<per-app>}   dry-run: $DRY_RUN   assume-yes: $ASSUME_YES"
for app in $APPS; do
  [[ -z "${NS[$app]:-}" ]] && { echo "unknown app: $app" >&2; continue; }
  do_app "$app"
done
echo
echo "Done."
