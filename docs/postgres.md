# Postgres notes

Most apps use the shared CNPG cluster `postgres` in `dbms` (pocket-id, lubelog, grampsweb, teslamate); see its [README](../kubernetes/apps/dbms/postgres/README.md) for isolation and how to add a tenant. Apps that need superuser or an extension image keep a dedicated cluster from the [postgres component](../kubernetes/components/postgres/README.md) (tracearr, sparkyfitness); those clusters are named `<app>-db`, in the app's namespace.

## Shared cluster

- Trigger a manual S3 base backup
  ```
  kubectl annotate cluster postgres -n dbms postgresql.cnpg.io/backup=true --overwrite
  ```
- Open a psql shell on the primary (superuser access is local-socket only; app roles cannot log in as another app's role)
  ```
  kubectl exec -it -n dbms postgres-1 -c postgres -- psql -d <database>
  ```
- Run a logical dump now (writes to the NFS share)
  ```
  kubectl create job -n dbms --from=cronjob/postgres-backup postgres-backup-manual
  ```

## Dedicated clusters

- Trigger a manual S3 base backup
  ```
  kubectl annotate cluster <app>-db -n <namespace> postgresql.cnpg.io/backup=true --overwrite
  ```
- Open a psql shell on the primary
  ```
  kubectl exec -it -n <namespace> <app>-db-1 -c postgres -- psql -U postgres -d <app>
  ```

## Either

- List tables
  ```
  \dt
  ```
