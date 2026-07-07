#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Validate all kustomize overlays in the GitOps repo render without errors.

.DESCRIPTION
  Runs 'kustomize build' on every overlay defined in the repo and reports
  which succeed/fail. Does not apply anything to a cluster.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$overlays = @(
    "platform/bootstrap/namespaces",
    "platform/bootstrap/argocd-apps",
    "platform/ingress-nginx/overlays/dev",
    "platform/postgres/overlays/dev",
    "platform/postgres/bootstrap",
    "platform/pgadmin/overlays/dev",
    "platform/kafka/overlays/dev",
    "platform/connect/overlays/dev",
    "platform/kafka/bootstrap",
    "platform/kafka-ui/overlays/dev",
    "platform/observability/otel-collector/overlays/dev",
    "platform/observability/prometheus/overlays/dev",
    "platform/observability/grafana/overlays/dev",
    "platform/policies",
    "platform/projects"
)

$passed = @()
$failed = @()

foreach ($overlay in $overlays) {
    Write-Host "Building $overlay ..." -NoNewline
    $output = kustomize build $overlay 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host " OK" -ForegroundColor Green
        $passed += $overlay
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        Write-Host $output -ForegroundColor Yellow
        $failed += $overlay
    }
}

Write-Host "`n─── Results ───────────────────────────────────────"
Write-Host "Passed: $($passed.Count)  Failed: $($failed.Count)"

if ($failed.Count -gt 0) {
    Write-Host "`nFailed overlays:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
