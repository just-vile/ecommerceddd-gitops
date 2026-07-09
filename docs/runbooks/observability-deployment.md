# Observability Deployment Runbook (Dev Cluster)

This runbook deploys the observability stack from this repo to your Kubernetes cluster:
- OpenTelemetry Collector
- Prometheus (kube-prometheus-stack)
- Grafana

## 1. Prerequisites

1. Confirm cluster access:

```powershell
kubectl cluster-info
kubectl get nodes
```

2. Confirm required namespaces and Argo CD are present:

```powershell
kubectl get ns argocd platform
kubectl get pods -n argocd
```

3. Confirm the platform app-of-apps includes observability apps:

- `platform/bootstrap/argocd-apps/platform-observability-app.yaml`
- `platform/bootstrap/argocd-apps/kustomization.yaml`

## 2. Pre-flight Render Validation

Validate overlays before syncing to the cluster:

```powershell
kubectl kustomize platform/observability/otel-collector/overlays/dev | Out-Null
kubectl kustomize platform/observability/prometheus/overlays/dev | Out-Null
kubectl kustomize platform/observability/grafana/overlays/dev | Out-Null
```

Optional full validation:

```powershell
.\scripts\validate-render.ps1
```

If Grafana overlay render fails with a missing `dashboards-configmap.yaml` file, check `platform/observability/grafana/overlays/dev/kustomization.yaml` for an extra dashboards entry and keep only valid resources.

## 3. Commit And Push GitOps Changes

If you made any observability manifest changes:

```powershell
git add platform/observability docs/runbooks
git commit -m "chore(observability): prepare dev deployment"
git push
```

If no changes were needed, continue to step 4.

## 4. Ensure Argo CD Applications Exist

Apply app definitions if they are not already managed:

```powershell
kubectl apply -k platform/bootstrap/argocd-apps
```

Verify app objects:

```powershell
kubectl get applications -n argocd | Select-String "platform-observability-dev|platform-prometheus-dev|platform-grafana-dev"
```

## 5. Wait For Reconciliation

1. Watch application health and sync state:

```powershell
kubectl get applications -n argocd -w
```

2. Wait until these are `Synced` and `Healthy`:
- `platform-observability-dev`
- `platform-prometheus-dev`
- `platform-grafana-dev`

## 6. Verify Workloads In Namespace

```powershell
kubectl get deploy,sts,svc,pods -n platform
```

Expected key resources:
- `otel-collector` Deployment and Service
- `prometheus-kube-prometheus-prometheus` StatefulSet/Pods
- `grafana` Deployment/Pods and Ingress

## 7. Functional Smoke Checks

1. OTel Collector health endpoint:

```powershell
kubectl port-forward -n platform svc/otel-collector 13133:13133
# In a second terminal:
Invoke-WebRequest http://localhost:13133/
```

2. Prometheus UI:

```powershell
kubectl port-forward -n platform svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090
```

3. Grafana UI:

```powershell
kubectl get ingress -n platform
kubectl port-forward -n platform svc/grafana 3000:80
# Open http://localhost:3000
```

4. Confirm Grafana datasource connectivity:
- Log in and check that Prometheus datasource is healthy.
- Confirm default dashboard folder `EcommerceDDD` is present.

## 8. Post-Deployment Checks

1. Confirm Prometheus is scraping OTel exporter target `otel-collector.platform.svc.cluster.local:8889`.
2. Confirm cluster resource usage is acceptable:

```powershell
kubectl top pods -n platform
```

3. Check for recurring restarts/errors:

```powershell
kubectl get pods -n platform
kubectl logs -n platform deploy/otel-collector --tail=200
```

## 9. Rollback Procedure

If deployment causes issues:

1. Revert the last observability manifest commit:

```powershell
git revert <commit_sha>
git push
```

2. Wait for Argo CD to reconcile automatically.

3. If immediate stop is required, scale down impacted workloads temporarily:

```powershell
kubectl scale deploy/otel-collector -n platform --replicas=0
kubectl scale deploy/grafana -n platform --replicas=0
```

Then restore desired state via Git and Argo CD.
