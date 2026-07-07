#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bootstrap a Minikube cluster and install Argo CD for EcommerceDDD GitOps.

.DESCRIPTION
  1. Starts Minikube with suitable resources for the full EcommerceDDD stack.
  2. Enables required addons (ingress, storage).
  3. Creates the argocd namespace and installs Argo CD via kustomize.
  4. Applies the root App-of-Apps to kick off GitOps reconciliation.

.PARAMETER Profile
  Minikube profile name. Default: ecommerceddd

.PARAMETER GitOpsRepoURL
  HTTPS URL of the EcommerceDDD-gitops repository.
  Default: https://github.com/YOUR_ORG/EcommerceDDD-gitops

.EXAMPLE
  .\bootstrap-minikube.ps1 -GitOpsRepoURL https://github.com/myorg/EcommerceDDD-gitops
#>
[CmdletBinding()]
param(
    [string] $Profile = "ecommerceddd",
    [string] $GitOpsRepoURL = "https://github.com/YOUR_ORG/EcommerceDDD-gitops"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string]$msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Assert-Command([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' not found. Please install it and retry."
    }
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────
Write-Step "Checking required tools"
@("minikube", "kubectl", "kustomize", "helm") | ForEach-Object { Assert-Command $_ }

# ─── Minikube cluster ─────────────────────────────────────────────────────────
Write-Step "Starting Minikube profile '$Profile'"
minikube start `
    --profile $Profile `
    --cpus 6 `
    --memory 10240 `
    --disk-size 40g `
    --driver docker `
    --kubernetes-version v1.32.0 `
    --addons ingress,ingress-dns,storage-provisioner,default-storageclass

# Set kubectl context
minikube update-context --profile $Profile

Write-Step "Verifying cluster"
kubectl cluster-info

# ─── Namespace: argocd ────────────────────────────────────────────────────────
Write-Step "Creating argocd namespace"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# ─── Install Argo CD ──────────────────────────────────────────────────────────
Write-Step "Installing Argo CD via kustomize"
kustomize build platform/bootstrap/argo-cd-install | kubectl apply -f -

Write-Step "Waiting for Argo CD server to be ready (up to 5 minutes)"
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# ─── Retrieve initial admin password ─────────────────────────────────────────
Write-Step "Retrieving initial Argo CD admin password"
$argoPass = kubectl -n argocd get secret argocd-initial-admin-secret `
    -o jsonpath="{.data.password}" | `
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_))
Write-Host "  Username: admin"
Write-Host "  Password: $argoPass"
Write-Host "  (Change this password immediately after first login)"

# ─── Apply root App-of-Apps ──────────────────────────────────────────────────
Write-Step "Patching repo URL in root-application.yaml to $GitOpsRepoURL"
$rootAppPath = "platform/bootstrap/root-app/root-application.yaml"
$content = Get-Content $rootAppPath -Raw
$content = $content -replace 'https://github.com/YOUR_ORG/EcommerceDDD-gitops', $GitOpsRepoURL
$content | Set-Content $rootAppPath

Write-Step "Applying root App-of-Apps"
kubectl apply -f platform/bootstrap/root-app/root-application.yaml

# ─── Port-forward helper ─────────────────────────────────────────────────────
Write-Step "Bootstrap complete!"
Write-Host @"

  Argo CD is running. Access the UI:
    kubectl port-forward svc/argocd-server -n argocd 8080:80
    then open http://localhost:8080

  Or via Minikube ingress (after DNS resolves):
    http://argocd.dev.ecommerceddd.local

  Argo CD admin credentials:
    Username: admin
    Password: $argoPass

  Next steps:
    1. Log in and change the admin password.
    2. Wait for the 'root' app to sync all platform components.
    3. Verify namespaces: kubectl get ns
    4. Monitor sync: kubectl get applications -n argocd -w
"@
