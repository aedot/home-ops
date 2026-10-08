# Postgres notes

Per-app CNPG clusters are defined by the [postgres component](../kubernetes/components/postgres/README.md). Cluster names are `<app>-db`, in the app's namespace.

- Trigger a manual S3 base backup
  ```
  kubectl annotate cluster <app>-db -n <namespace> postgresql.cnpg.io/backup=true --overwrite
  ```
- Open a psql shell on the primary
  ```
  kubectl exec -it -n <namespace> <app>-db-1 -c postgres -- psql -U postgres -d <app>
  ```
- List tables
  ```
  \dt
  ```
