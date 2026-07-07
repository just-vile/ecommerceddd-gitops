#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Update an image tag in a dev values file for a given service.
  Called by Repository A CI after a successful image build.

.PARAMETER Service
  Service name (e.g. order-processing). Corresponds to
  apps/environments/dev/values/<service>.yaml

.PARAMETER Tag
  New image tag (e.g. sha-abc1234)

.EXAMPLE
  .\bump-image-tag.ps1 -Service order-processing -Tag sha-abc1234
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Service,

    [Parameter(Mandatory)]
    [string] $Tag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$valuesFile = "apps/environments/dev/values/$Service.yaml"

if (-not (Test-Path $valuesFile)) {
    throw "Values file not found: $valuesFile"
}

Write-Host "Bumping $Service image tag to $Tag in $valuesFile"

# Use yq if available, otherwise fall back to simple sed-like replacement
if (Get-Command yq -ErrorAction SilentlyContinue) {
    yq -i ".image.tag = `"$Tag`"" $valuesFile
} else {
    $content = Get-Content $valuesFile -Raw
    # Replace lines matching: tag: <anything>
    $content = $content -replace '(\s+tag:\s+).*', "`$1`"$Tag`""
    $content | Set-Content $valuesFile -NoNewline
}

Write-Host "Updated $valuesFile"
git add $valuesFile
git commit -m "chore(dev): bump $Service to $Tag [skip ci]"
git push
