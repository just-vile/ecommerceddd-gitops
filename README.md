# EcommerceDDD GitOps Repository

Kubernetes manifests and platform configuration for the [EcommerceDDD](https://github.com/YOUR_ORG/EcommerceDDD) application.  
Managed by [Argo CD](https://argoproj.github.io/cd/) using the App-of-Apps pattern.

---

## Quick Start (Minikube + Argo CD)

### Prerequisites

| Tool | Version |
|---|---|
| minikube | ≥ 1.35 |
| kubectl | ≥ 1.32 |
| kustomize | ≥ 5.6 |
| helm | ≥ 3.17 |
| kubeseal | ≥ 0.27 (for encrypting secrets) |

### Bootstrap

```powershell
git clone https://github.com/YOUR_ORG/EcommerceDDD-gitops
cd EcommerceDDD-gitops

# Start Minikube + install Argo CD + apply root App-of-Apps
.\scripts\bootstrap-minikube.ps1 -GitOpsRepoURL https://github.com/YOUR_ORG/EcommerceDDD-gitops
```

### Validate renders locally (no cluster needed)

```powershell
.\scripts\validate-render.ps1
```

---

## Repository Structure

```
platform/                      # Cluster infrastructure (Argo CD project: project-platform)
  bootstrap/
    namespaces/                # ecom-dev, platform, data namespaces
    argo-cd-install/           # Argo CD Helm chart + values
    root-app/                  # Root App-of-Apps (applied once manually)
    argocd-apps/               # Application CRs for every platform component
  projects/                    # Argo CD AppProject definitions
  ingress-nginx/               # ingress-nginx Helm chart + dev overlay
  cert-manager/                # cert-manager + self-signed issuers for dev
  sealed-secrets/              # Sealed Secrets controller
  cnpg/                        # CloudNativePG operator + Postgres cluster + DB init job
  strimzi/                     # Strimzi operator + Kafka + KafkaConnect + Topics
  observability/               # OTel Collector, Prometheus (kube-prometheus-stack), Grafana
  policies/                    # NetworkPolicies, ResourceQuotas, image policies (Kyverno)

apps/                          # Business workloads (Argo CD project: project-apps)
  charts/                      # Reusable Helm charts for .NET microservices
  environments/dev/            # Per-service values for dev environment
  argocd/apps/dev/             # Argo CD Application CRs for each service

scripts/
  bootstrap-minikube.ps1       # One-shot cluster bootstrap script
  validate-render.ps1          # Local kustomize build validation
  bump-image-tag.ps1           # Update image tag in values (called by CI)

.github/workflows/
  validate-manifests.yml       # PR: helm lint + kustomize build + kubeconform
  policy-checks.yml            # PR: no-latest-tag, no staging/prod refs, conftest
```

---

## Namespaces

| Namespace | Purpose | Pod Security |
|---|---|---|
| `platform` | Argo CD, ingress-nginx, cert-manager, sealed-secrets, observability | baseline |
| `data` | Postgres (CNPG), Kafka (Strimzi), Debezium Connect | baseline |
| `ecom-dev` | All EcommerceDDD application services | restricted |

## Service DNS (within cluster)

| Resource | Address |
|---|---|
| Postgres (read-write) | `ecom-postgres-dev-rw.data.svc.cluster.local:5432` |
| Kafka bootstrap | `ecom-kafka-dev-kafka-bootstrap.data.svc.cluster.local:9092` |
| Debezium Connect | `ecom-connect-dev-connect-api.data.svc.cluster.local:8083` |
| OTel Collector (gRPC) | `otel-collector.platform.svc.cluster.local:4317` |
| OTel Collector (HTTP) | `otel-collector.platform.svc.cluster.local:4318` |

## Ingress Hostnames (dev)

Add these to `/etc/hosts` → Minikube IP (`minikube ip --profile ecommerceddd`):

```
<minikube-ip>  argocd.dev.ecommerceddd.local
<minikube-ip>  api.dev.ecommerceddd.local
<minikube-ip>  app.dev.ecommerceddd.local
<minikube-ip>  id.dev.ecommerceddd.local
<minikube-ip>  hub.dev.ecommerceddd.local
<minikube-ip>  grafana.dev.ecommerceddd.local
```

---

## Secrets Management

Secrets are encrypted with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).  
**Never commit plaintext secrets.**

```powershell
# Encrypt a secret for a specific namespace
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  kubeseal \
    --controller-namespace platform \
    --controller-name sealed-secrets-controller \
    --format yaml > apps/environments/dev/secrets/my-secret.yaml
```

Sealed secrets live in `apps/environments/dev/secrets/`.

---

## Sync Order (Argo CD sync waves)

| Wave | Components |
|---|---|
| 0 | Namespaces, Argo CD Projects |
| 1 | ingress-nginx, cert-manager, sealed-secrets |
| 2 | CNPG operator, Strimzi operator, Apps aggregator |
| 3 | CNPG cluster, Kafka cluster, KafkaConnect |
| 4 | Kafka topics, OTel Collector, Prometheus, Grafana |
| 5 | Policies |

---

## Environments

| Environment | Namespace | Auto-sync | Status |
|---|---|---|---|
| dev | `ecom-dev` | ✅ enabled | Active |
| staging | — | — | Deferred (not created) |
| prod | — | — | Deferred (not created) |

---

## Runbooks

See [docs/runbooks/](docs/runbooks/) for:
- Platform bootstrap and recovery
- Postgres (CNPG) restore
- Kafka (Strimzi) recovery
- Secret rotation
- Rollback via `git revert`
