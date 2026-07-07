# CNPG (Postgres) Recovery Runbook

## Check cluster status

```bash
kubectl get cluster ecom-postgres-dev -n data
kubectl describe cluster ecom-postgres-dev -n data
kubectl get pods -n data -l cnpg.io/cluster=ecom-postgres-dev
```

## Primary failover (manual)

```bash
# List instances
kubectl get pods -n data -l cnpg.io/cluster=ecom-postgres-dev

# Promote a standby (if instances > 1)
kubectl cnpg promote ecom-postgres-dev -n data
```

## Point-in-time restore

```bash
# Edit cluster.yaml to add recovery source, then apply via Git PR
# See: https://cloudnative-pg.io/documentation/current/recovery/
```

## Re-run DB init job (if databases are missing)

```bash
kubectl delete job ecom-db-init -n data 2>/dev/null || true
kubectl apply -f platform/cnpg/bootstrap/db-init-job.yaml
kubectl wait --for=condition=complete job/ecom-db-init -n data --timeout=120s
```
