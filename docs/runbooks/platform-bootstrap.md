# Platform Bootstrap Runbook

## First-time install

```powershell
# From the EcommerceDDD-gitops repo root
.\scripts\bootstrap-minikube.ps1 -GitOpsRepoURL https://github.com/YOUR_ORG/EcommerceDDD-gitops
```

## Verify

```bash
# All namespaces exist
kubectl get ns ecom-dev platform data

# Argo CD apps syncing
kubectl get applications -n argocd

# CNPG cluster ready
kubectl get cluster -n data

# Kafka ready
kubectl get kafka -n data

# OTel Collector running
kubectl get pods -n platform -l app.kubernetes.io/name=otel-collector
```

## Recovery (cluster lost)

1. Run `.\scripts\bootstrap-minikube.ps1` on a fresh Minikube profile.
2. Restore the Sealed Secrets master key from backup:
   ```bash
   kubectl apply -f <sealed-secrets-key-backup>.yaml -n platform
   kubectl rollout restart deployment/sealed-secrets-controller -n platform
   ```
3. Re-apply root app: `kubectl apply -f platform/bootstrap/root-app/root-application.yaml`
4. Argo CD reconciles everything from Git automatically.

## Upgrade Argo CD

1. Update `version` in `platform/bootstrap/argo-cd-install/kustomization.yaml`.
2. Open PR → CI validates → merge → Argo CD self-updates.
