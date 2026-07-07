# EcommerceDDD Secrets Standardization Implementation Plan (Minikube)

Author: DevOps Engineering  
Scope: Standardize secret naming, file layout, ownership, validation, and promotion for the two-repo model using Minikube and manually bootstrapped Kubernetes Secrets.  
Status: Implementation plan v1

---

## 1. Objective

Create a consistent, GitOps-safe secret management model that is:
- Environment-scoped for `dev` namespace on Minikube (staging/prod deferred)
- Version-controlled for secret contracts and key schemas, while keeping secret values out of Git
- Reviewable in PR workflows for naming and allowed keys
- Enforceable via policy and CI checks

---

## 2. Standard Convention to Implement

## 2.1 Folder structure in GitOps repo

Target location in Repository B (`EcommerceDDD-gitops`):

```text
apps/
  environments/
    dev/
      secrets/
        customer-management/
        product-catalog/
        inventory-management/
        quote-management/
        order-processing/
        payment-processing/
        shipment-processing/
        apigateway/
        identityserver/
        signalr/
        spa/
    README.md
```

Rules:
- One service folder per environment.
- Current implementation creates service folders for `dev` only.
- No shared/global secret files unless explicitly approved.
- Staging/prod secret folders are documentation-only placeholders until explicitly approved.

## 2.2 Secret resource naming

Kubernetes Secret names:
- `<service>-secrets`

Examples:
- `order-processing-secrets`
- `identityserver-secrets`
- `spa-secrets`

## 2.3 Key naming convention

Secret keys must map directly to .NET/SPA runtime environment variable names.

Pattern:
- .NET nested settings use double underscore: `Section__SubSection__Key`
- Flat credentials use explicit app-level prefixes when needed

Examples:
- `ConnectionStrings__DefaultConnection`
- `TokenIssuerSettings__ClientSecret`
- `KafkaConsumer__ConnectionString`
- `DebeziumSettings__DatabasePassword`

Forbidden:
- Generic keys like `password`, `secret`, `token` without context.
- Lowercase ad-hoc keys that do not map to runtime config.

## 2.4 Labels and annotations convention

All Secret objects and any related templates should include:
- `app.kubernetes.io/name: <service>`
- `app.kubernetes.io/part-of: ecommerceddd`
- `app.kubernetes.io/managed-by: argocd`
- `ecommerceddd.io/environment: <dev|staging|prod>`
- `ecommerceddd.io/secret-scope: service`

---

## 3. File-Level Convention

For each service folder:

```text
apps/environments/<env>/secrets/<service>/
  README.md
  keys.allowed.txt
```

File purposes:
- `README.md`: service-specific usage notes and ownership.
- `keys.allowed.txt`: allowed key whitelist used by CI policy check.

Note:
- `keys.allowed.txt` is non-sensitive and must not contain values.
- Secret values are created out of band with `kubectl create secret` and must not be committed.

---

## 4. Ownership and Approval Model

- Service team owns key schema for its service (`keys.allowed.txt`).
- Platform/App platform team owns secret bootstrap guidance, policy, and CI enforcement.
- PR approval requirement:
  - At least one service owner reviewer for service key changes.
  - At least one platform reviewer for secret manifest structural changes.

CODEOWNERS (in GitOps repo) should enforce this automatically.

---

## 5. CI and Policy Controls to Implement

## 5.1 PR validation checks

Add in GitOps workflows:
1. Ensure only allowed keys are present in documented service contracts (compare against `keys.allowed.txt`).
2. Block plaintext secret resources:
   - fail if `kind: Secret` with literal value fields (`stringData`, raw cleartext patterns) appears in app env folders.
3. Block malformed names:
   - fail if secret name does not match `<service>-secrets`.

## 5.2 Suggested policy toolchain

- Basic checks: `yq` + shell/PowerShell scripts
- Structural policy: `conftest` (OPA Rego) or Kyverno CLI in CI
- Secret leak detection: `gitleaks` + regex guardrails

---

## 6. Step-by-Step Implementation Plan

## Phase 1: Baseline conventions and templates

1. Create folder skeleton for all environments and services under `apps/environments/*/secrets/`.
2. Add template files:
   - `README.md` template per service
   - `keys.allowed.txt` template per service
3. Add a canonical bootstrap example for one service (`order-processing`) showing the `kubectl create secret` command shape.

Deliverable:
- Convention-first commit with no secret values.

## Phase 2: Dev secret bootstrap

1. Create a local helper script:
   - Input: env, service, key/value source
   - Output: `kubectl create secret` or `kubectl apply -f -` commands for the target namespace
2. Document command usage in each service secret `README.md`.

Deliverable:
- Repeatable command to create/update required Secrets out of band.

## Phase 3: Service-by-service migration

1. Build migration inventory from appsettings and current env vars.
2. For each service:
   - Define allowed keys in `keys.allowed.txt`
   - Create the required Secret in `dev` out of band
   - Reference `<service>-secrets` in chart values/deployment templates
3. Validate app startup in `ecom-dev` namespace.
4. Repeat for all 11 components.

Deliverable:
- All services in dev consume standardized secret naming.

## Phase 4: Deferred environments (no resource creation)

1. Keep staging/prod conventions in documentation only.
2. Do not generate or commit staging/prod Secret manifests containing values.
3. Enforce CI checks to block accidental staging/prod secret resource creation.

Deliverable:
- Dev-only out-of-band secret bootstrap with guardrails.

## Phase 5: Guardrails and operational hardening

1. Enable mandatory CI checks on secret files.
2. Add CODEOWNERS path rules for secret folders.
3. Add runbook for secret rotation and rollback.
4. Add quarterly secret key schema review process.

Deliverable:
- Governance-complete secret management lifecycle.

---

## 7. Rotation, Rollback, and Emergency Procedures

## 7.1 Rotation

1. Update source value securely in operator workstation.
2. Recreate or update the target Kubernetes Secret for the env/service.
3. PR with rotation note (no plaintext).
4. Merge and allow Argo CD sync.
5. Restart workload if hot reload is unavailable.

## 7.2 Rollback

1. Reapply the previous Secret value from the secure operator source.
2. Sync or restart the affected workload if needed.
3. Confirm pod health and dependency connectivity.

## 7.3 Emergency break-glass

1. Temporarily pause Argo CD auto-sync on impacted app.
2. Apply emergency Secret update out of band using a controlled operator workflow.
3. Resume auto-sync after validation.

---

## 8. Definition of Done

Implementation is complete when:
1. Every service has standardized secret documentation and `keys.allowed.txt` in `dev` folders.
2. Every service uses `<service>-secrets` consistently in dev deployment manifests.
3. CI blocks non-conforming secret names, keys, plaintext patterns, and staging/prod secret resource creation.
4. Secret rotation and rollback runbooks are tested in `dev`.
5. Argo CD sync succeeds in `ecom-dev` without manual patching.

---

## 9. Immediate Next Actions

1. Create `apps/environments/dev/secrets/` skeleton in the GitOps repo.
2. Standardize one pilot service first (`order-processing`) end-to-end.
3. Add CI policy checks before migrating remaining services.
4. Migrate remaining services in batches (edge services last).
