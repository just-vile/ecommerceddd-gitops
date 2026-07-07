# PostgreSQL and pgAdmin Migration Plan (Docker Compose to Minikube with Argo CD)

Date: 2026-07-07  
Scope: Dev environment only (`ecom-dev`, `platform`, `data`)  
Target: Migrate PostgreSQL and pgAdmin from Docker Compose to Minikube with Argo CD GitOps

## Status

**Implemented 2026-07-07.**

- `platform/postgres/` and `platform/pgadmin/` created (base + overlays/dev + bootstrap).
- Argo CD apps: `platform-postgres-dev` (wave 1), `platform-postgres-bootstrap-dev` (wave 2), `platform-pgadmin-dev` (wave 3).
- CloudNativePG (CNPG) operator and cluster manifests removed; `platform/cnpg/` deleted.
- Debezium connectors updated: `database.hostname` changed from `ecom-postgres-dev-rw.data.svc.cluster.local` to `postgres.data.svc.cluster.local`.
- NetworkPolicy `allow-ecom-dev-to-postgres` updated: pod selector changed from `cnpg.io/cluster: ecom-postgres-dev` to `app.kubernetes.io/name: postgres`.
- Secrets required before bootstrap:
  - `kubectl create secret generic ecom-postgres-superuser --namespace data --from-literal=username=postgres --from-literal=password=<PW>`
  - `kubectl create secret generic ecom-pgadmin --namespace platform --from-literal=email=<EMAIL> --from-literal=password=<PW>`

## 1. Decisions

- PostgreSQL deployment model: vanilla StatefulSet + PVC + ClusterIP Service.
- pgAdmin scope: Argo-managed workload in platform namespace.
- Database initialization: Kubernetes Job managed by Argo CD.
- Environment scope: dev only; no staging/prod resources in this phase.

## 2. Current-State Inputs to Preserve

From current compose behavior:

- PostgreSQL image/version: `postgres:18`.
- PostgreSQL runtime flags:
  - `wal_level=logical`
  - `max_wal_senders=5`
  - `max_replication_slots=5`
- PostgreSQL health behavior: `pg_isready -U postgres`.
- SQL initialization source: `scripts/db_init.sql`.
- pgAdmin image: `dpage/pgadmin4:latest`.
- pgAdmin environment defaults:
  - `PGADMIN_DEFAULT_EMAIL`
  - `PGADMIN_DEFAULT_PASSWORD`
  - `PGADMIN_CONFIG_SERVER_MODE=False`

## 3. Migration Objectives

1. Replace Compose Postgres with Kubernetes-native Postgres on Minikube.
2. Keep database bootstrap fully automated and repeatable.
3. Run pgAdmin as a GitOps-managed operational tool.
4. Ensure Argo CD controls lifecycle and drift reconciliation.
5. Keep services functional via Kubernetes DNS and secrets-driven configuration.

## 4. GitOps Layout (Platform Slice)

Suggested structure in GitOps repo:

- `platform/postgres/base/`
  - `statefulset.yaml`
  - `service.yaml`
  - `pvc.yaml` (if not in StatefulSet template)
  - `configmap.yaml`
  - `secret-refs.md` (documentation only)
  - `kustomization.yaml`
- `platform/postgres/overlays/dev/`
  - `kustomization.yaml`
  - `patch-resources.yaml`
  - `patch-storage.yaml`
- `platform/postgres/bootstrap/`
  - `db-init-job.yaml`
  - `configmap-db-init-sql.yaml` (or mounted SQL strategy)
- `platform/pgadmin/base/`
  - `deployment.yaml`
  - `service.yaml`
  - `kustomization.yaml`
- `platform/pgadmin/overlays/dev/`
  - `kustomization.yaml`
  - `ingress.yaml` (or keep port-forward only)

## 5. Argo CD Application Topology and Sync Order

Create separate Argo apps for isolation:

1. `platform-postgres-dev`
2. `platform-postgres-bootstrap-dev`
3. `platform-pgadmin-dev`

Use sync waves:

- Wave 0: namespaces, projects, prerequisites, required secrets precheck docs.
- Wave 1: PostgreSQL StatefulSet + Service + PVC.
- Wave 2: DB bootstrap Job (`db_init.sql`).
- Wave 3: pgAdmin Deployment + Service (+ Ingress if used).
- Wave 4: dependent app workloads (outside this specific migration slice).

## 6. PostgreSQL Kubernetes Design

Required resources:

- StatefulSet (1 replica for dev)
- ClusterIP Service
- PersistentVolumeClaim (Minikube storage class)
- Secret for credentials
- ConfigMap for runtime arguments where appropriate
- Probes:
  - readiness using `pg_isready`
  - liveness using `pg_isready`

Configuration parity:

- Keep Postgres 18.
- Keep logical replication parameters from compose.
- Keep internal service port 5432.
- Ensure mounted data path is persistent across pod restarts.

Sizing (initial dev baseline):

- Requests: 250m CPU / 512Mi memory
- Limits: 1000m CPU / 2Gi memory
- PVC: 20Gi (adjust based on test data growth)

## 7. DB Initialization Strategy

Migrate `scripts/db_init.sql` into Kubernetes bootstrap flow.

Databases to create:

- `identityserverdb`
- `productsdb`
- `inventorydb`
- `customersdb`
- `quotesdb`
- `ordersdb`
- `paymentsdb`
- `shipmentsdb`

Implementation notes:

- Run as Kubernetes Job after Postgres becomes healthy.
- Make logic idempotent (safe to rerun).
- Expose clear logs for Argo troubleshooting.
- Fail fast on SQL errors.

## 8. pgAdmin Kubernetes Design

Required resources:

- Deployment (1 replica)
- Service (ClusterIP)
- Secret with pgAdmin credentials
- Optional PVC for pgAdmin metadata persistence
- Optional Ingress for browser access

Runtime settings:

- Keep `PGADMIN_CONFIG_SERVER_MODE=False` for local dev behavior.
- Inject `PGADMIN_DEFAULT_EMAIL` and `PGADMIN_DEFAULT_PASSWORD` from secret.
- Preconfigure server registration to Postgres service DNS when feasible.

Access model:

- Preferred for small dev teams: `kubectl port-forward`.
- Alternative: Ingress with local TLS and controlled host mapping.

## 9. Secrets and Configuration Cutover

Do not keep live secrets in Git.

Use pre-created Kubernetes secrets for:

- Postgres superuser/admin password
- pgAdmin admin email/password
- App-level connection strings or split host/user/password fields

Standardize key names and references to avoid per-service drift.

## 10. Application Connectivity Cutover

Move runtime host references from compose names to Kubernetes DNS.

Examples:

- Postgres endpoint: `postgres.data.svc.cluster.local:5432` (or chosen service name)
- Ensure all service env overrides use Kubernetes endpoint and secret-managed credentials.
- Validate Debezium-related DB hostname settings if they still reference old compose hostnames.

## 11. Validation Checklist

1. Argo app `platform-postgres-dev` is Synced and Healthy.
2. PostgreSQL pod Ready; PVC Bound and mounted.
3. Runtime parameters include logical replication settings.
4. Bootstrap Job succeeds and all required databases exist.
5. Argo app `platform-pgadmin-dev` is Synced and Healthy.
6. pgAdmin login succeeds.
7. pgAdmin can connect to Postgres service.
8. At least one DB-dependent service performs read/write successfully.
9. Drift test: manual in-cluster change is reconciled by Argo.

## 12. Rollback Strategy

- Rollback by Git revert of Postgres/pgAdmin app manifests.
- Keep Postgres and pgAdmin as separate Argo apps for targeted rollback.
- For bootstrap issues, revert or patch Job manifest and re-sync.
- Document data caveat: Minikube local storage is not equivalent to production-grade backup/HA.

## 13. CI Policy Gates for This Slice

For PRs touching `platform/postgres/**` or `platform/pgadmin/**`:

1. Kustomize build validation (dev overlays).
2. Schema validation (kubeconform or equivalent).
3. Policy checks:
   - no floating `latest` tag for PostgreSQL/pgAdmin in final state
   - required sync-wave annotations present
   - dev-only scope enforcement (block staging/prod resources)

## 14. Execution Sequence (Practical)

1. Add namespace/prerequisite manifests if missing.
2. Add Postgres base + dev overlay.
3. Add and test DB bootstrap Job.
4. Add pgAdmin base + dev overlay.
5. Create/update Argo Applications with sync waves.
6. Pre-create required secrets in cluster.
7. Sync Argo apps in order.
8. Run validation checklist.
9. Execute rollback drill once in dev.

## 15. Done Criteria

Migration is complete when all conditions below are true:

1. PostgreSQL and pgAdmin are Argo-managed and healthy in Minikube dev.
2. All required databases are created automatically by Job.
3. At least one service validates DB read/write against Kubernetes Postgres.
4. Rollback by Git revert is tested successfully.
5. CI checks and policy gates are green and enforced for this platform slice.
