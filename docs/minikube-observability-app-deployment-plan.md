# Minikube Observability & App Service Deployment Plan

**Date**: 2026-07-08  
**Scope**: Deploy OTEL Collector → Aspire Dashboard, create Helm chart for .NET services, deploy 9 microservices to minikube via ArgoCD

---

## Current State

### Docker Compose (App Repo)
- ✅ All services send telemetry to `aspire-dashboard:18889`
- ✅ Aspire Dashboard aggregates traces, metrics, logs

### Minikube GitOps (Current)
- ✅ OTEL Collector: K8s Deployment + Service ready (ports: 4317 gRPC, 4318 HTTP, 8889 Prometheus)
- ✅ Prometheus & Grafana: Configured to scrape OTEL metrics
- ❌ App services: No K8s manifests, no Helm chart, no OTEL endpoint configuration
- ❌ Traces: Debug output only (no persistent backend)
- ❌ Aspire Dashboard: Not deployed to minikube

---

## Issues Before Landing Apps to Minikube

1. **Telemetry Lost**: Apps will try to reach non-existent `aspire-dashboard:18889` → all spans/metrics dropped
2. **No Deployment Automation**: Services must be deployed manually (no Helm chart, no ArgoCD Applications)
3. **No Environment-Specific Config**: `OTEL_EXPORTER_OTLP_ENDPOINT` not configurable per environment
4. **No Trace Persistence**: Prometheus scrapes metrics but traces vanish without backend
5. **Operational Drift**: Hard to debug why telemetry isn't flowing without unified dashboard

---

## User Decisions

- ✅ Deploy **Aspire Dashboard to minikube** (replaces Tempo complexity, maintains familiar docker-compose UX)
- ✅ Create **reusable Helm chart** for .NET services
- ✅ Deploy all **9 services via ArgoCD** with proper sync waves
- ✅ Use **gRPC (4317)** for OTLP protocol (faster, more efficient)

---

## Implementation Plan

### Phase 1: Update OTEL Collector to Export to Aspire Dashboard
**Status**: NOT STARTED  
**Dependencies**: None  
**Files to Modify**:
- `platform/observability/otel-collector/base/configmap.yaml`

**Changes**:
1. Add `otlphttp` exporter in `exporters` section:
   ```yaml
   exporters:
     otlphttp:
       endpoint: http://aspire-dashboard.platform.svc.cluster.local:18889
       tls:
         insecure: true
   ```
2. Update traces pipeline to export to Aspire:
   ```yaml
   service:
     pipelines:
       traces:
         receivers: [otlp]
         processors: [memory_limiter, batch, resource]
         exporters: [otlphttp, debug]  # Add otlphttp
   ```
3. Keep metrics pipeline → Prometheus (unchanged)
4. Keep logs pipeline → debug output (unchanged)

**Verification**: OTEL Collector logs show `otlphttp exporter started`

---

### Phase 2: Deploy Aspire Dashboard to Minikube
**Status**: NOT STARTED  
**Dependencies**: Phase 1 (OTEL exporter configured)  
**Files to Create**:
- `platform/observability/aspire-dashboard/base/deployment.yaml`
- `platform/observability/aspire-dashboard/base/service.yaml`
- `platform/observability/aspire-dashboard/base/configmap.yaml` (optional)
- `platform/observability/aspire-dashboard/base/kustomization.yaml`
- `platform/observability/aspire-dashboard/overlays/dev/kustomization.yaml`
- `platform/bootstrap/argocd-apps/platform-aspire-dashboard-app.yaml`

**Specifications**:
- **Image**: `mcr.microsoft.com/dotnet/aspire-dashboard:9.1`
- **Namespace**: `platform`
- **Port**: 18889 (internal), expose via Service ClusterIP
- **Replicas**: 1 (single instance for dev)
- **Environment**:
  ```
  DOTNET_DASHBOARD_UNSECURED_ALLOW_ANONYMOUS=true  # Dev-only, no auth
  ```
- **Resources**:
  ```
  requests: cpu 50m, memory 128Mi
  limits: cpu 200m, memory 256Mi
  ```
- **Health Check**: HTTP GET `/health` at startup

**ArgoCD Integration**:
- Create Application CR with `sync-wave: 1` (before OTEL Collector finishes, Aspire Dashboard must be ready for receiver connections)
- Actually, **sync-wave: 2** (after OTEL Collector ready with traces exporter configured)

**Ingress** (Optional but Recommended):
- Hostname: `aspire.dev.ecommerceddd.local`
- Path: `/`
- Backend: Aspire Dashboard Service:18889

**Verification**:
1. `kubectl get pod -n platform | grep aspire-dashboard` → Running/Ready
2. `kubectl port-forward -n platform svc/aspire-dashboard 18889:18889`
3. Open `http://localhost:18889` → Aspire Dashboard UI loads

---

### Phase 3: Create Reusable Helm Chart for .NET Services
**Status**: NOT STARTED  
**Dependencies**: None  
**Files to Create**:
- `apps/charts/ecommerceddd-service/Chart.yaml`
- `apps/charts/ecommerceddd-service/values.yaml`
- `apps/charts/ecommerceddd-service/templates/deployment.yaml`
- `apps/charts/ecommerceddd-service/templates/service.yaml`
- `apps/charts/ecommerceddd-service/templates/serviceaccount.yaml`
- `apps/charts/ecommerceddd-service/templates/NOTES.txt`

**Chart Metadata** (`Chart.yaml`):
```yaml
apiVersion: v2
name: ecommerceddd-service
description: Helm chart for EcommerceDDD .NET microservices
type: application
version: 1.0.0
appVersion: "1.0"
```

**Default Values** (`values.yaml`):
```yaml
replicaCount: 1

image:
  repository: ""  # Override per service (e.g., ecommerceddd-api-gateway)
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: 80

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

livenessProbe:
  httpGet:
    path: /health
    port: 80
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /health
    port: 80
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 2

# Environment variables (OTEL configuration)
env:
  ASPNETCORE_ENVIRONMENT: Development
  ASPNETCORE_URLS: "http://+:80"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector.platform.svc.cluster.local:4317"
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"

# Additional environment variables per service (Kafka, Postgres, etc.)
additionalEnv: {}
```

**Deployment Template** (`templates/deployment.yaml`):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "ecommerceddd-service.fullname" . }}
  labels:
    {{ include "ecommerceddd-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{ include "ecommerceddd-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{ include "ecommerceddd-service.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "ecommerceddd-service.serviceAccountName" . }}
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}
          protocol: TCP
        env:
        {{- range $key, $value := .Values.env }}
        - name: {{ $key }}
          value: {{ quote $value }}
        {{- end }}
        {{- range $key, $value := .Values.additionalEnv }}
        - name: {{ $key }}
          value: {{ quote $value }}
        {{- end }}
        livenessProbe:
          {{ toYaml .Values.livenessProbe | nindent 10 }}
        readinessProbe:
          {{ toYaml .Values.readinessProbe | nindent 10 }}
        resources:
          {{ toYaml .Values.resources | nindent 10 }}
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          capabilities:
            drop:
            - ALL
        volumeMounts:
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: tmp
        emptyDir: {}
```

**Service Template** (`templates/service.yaml`):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "ecommerceddd-service.fullname" . }}
  labels:
    {{ include "ecommerceddd-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: http
    protocol: TCP
    name: http
  selector:
    {{ include "ecommerceddd-service.selectorLabels" . | nindent 4 }}
```

**ServiceAccount Template** (`templates/serviceaccount.yaml`):
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "ecommerceddd-service.serviceAccountName" . }}
  labels:
    {{ include "ecommerceddd-service.labels" . | nindent 4 }}
```

**Helpers** (`templates/_helpers.tpl`):
```yaml
{{- define "ecommerceddd-service.fullname" -}}
{{ .Release.Name }}-{{ .Chart.Name }}
{{- end }}

{{- define "ecommerceddd-service.labels" -}}
helm.sh/chart: {{ include "ecommerceddd-service.chart" . }}
{{ include "ecommerceddd-service.selectorLabels" . }}
{{- end }}

{{- define "ecommerceddd-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ecommerceddd-service.serviceAccountName" -}}
{{ .Values.serviceAccount.name | default (include "ecommerceddd-service.fullname" .) }}
{{- end }}

{{- define "ecommerceddd-service.chart" -}}
{{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}
```

**Verification**: 
```bash
helm lint apps/charts/ecommerceddd-service
helm template test-release apps/charts/ecommerceddd-service --values apps/environments/dev/values-product-catalog.yaml
```

---

### Phase 4: Create Per-Service Values & ArgoCD Applications
**Status**: NOT STARTED  
**Dependencies**: Phase 3 (Helm chart exists)  
**Files to Create**:
- `apps/environments/dev/values-identity-server.yaml`
- `apps/environments/dev/values-api-gateway.yaml`
- `apps/environments/dev/values-signalr.yaml`
- `apps/environments/dev/values-customer-management.yaml`
- `apps/environments/dev/values-product-catalog.yaml`
- `apps/environments/dev/values-inventory-management.yaml`
- `apps/environments/dev/values-order-processing.yaml`
- `apps/environments/dev/values-payment-processing.yaml`
- `apps/environments/dev/values-shipment-processing.yaml`
- `apps/argocd/apps/dev/kustomization.yaml` (orchestrator)
- `apps/argocd/apps/dev/00-identity-server.yaml`
- `apps/argocd/apps/dev/01-services.yaml` (or separate per service)
- `apps/argocd/apps/dev/02-api-gateway.yaml`

**Example Values** (`apps/environments/dev/values-product-catalog.yaml`):
```yaml
replicaCount: 1

image:
  repository: ecommerceddd-product-catalog
  tag: latest
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: 80

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

additionalEnv:
  KAFKA_BOOTSTRAP_SERVERS: "kafka.data.svc.cluster.local:9092"
  POSTGRES_HOST: "postgres.data.svc.cluster.local"
  POSTGRES_USER: "postgres"
  # POSTGRES_PASSWORD: (from Sealed Secret)
```

**ArgoCD Application CRs** (with sync waves):

**Wave 0**: IdentityServer (no service dependencies)
```yaml
# apps/argocd/apps/dev/00-identity-server.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: identity-server
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: project-apps
  source:
    repoURL: https://github.com/YOUR_ORG/EcommerceDDD-gitops
    path: apps
    targetRevision: main
    helm:
      releaseName: identity-server
      chart: charts/ecommerceddd-service
      valuesObject:
        replicaCount: 1
        image:
          repository: ecommerceddd-identity-server
          tag: "{{ TARGET_IMAGE_TAG }}"
      valueFiles:
      - environments/dev/values-identity-server.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ecom-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=false
    - ServerSideApply=true
```

**Wave 1**: Service Microservices (depend on IdentityServer)
```yaml
# apps/argocd/apps/dev/01-services.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ecom-services
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: project-apps
  source:
    repoURL: https://github.com/YOUR_ORG/EcommerceDDD-gitops
    path: apps
    targetRevision: main
    # Deploy 8 services in one Application using Kustomize overlay
    kustomize:
      overlays:
      - overlays/dev/services
  destination:
    server: https://kubernetes.default.svc
    namespace: ecom-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=false
    - ServerSideApply=true
```
*(Alternative: Create 8 separate Applications, one per service, if finer control needed)*

**Wave 2**: API Gateway & SignalR (depend on all services)
```yaml
# apps/argocd/apps/dev/02-api-gateway.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-gateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: project-apps
  source:
    repoURL: https://github.com/YOUR_ORG/EcommerceDDD-gitops
    path: apps
    targetRevision: main
    helm:
      releaseName: api-gateway
      chart: charts/ecommerceddd-service
      valuesObject:
        replicaCount: 1
        image:
          repository: ecommerceddd-api-gateway
          tag: "{{ TARGET_IMAGE_TAG }}"
      valueFiles:
      - environments/dev/values-api-gateway.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ecom-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=false
    - ServerSideApply=true
```

**Verification**:
```bash
kubectl get applications -n argocd
kubectl describe application identity-server -n argocd
```

---

### Phase 5: Deploy and Verify End-to-End
**Status**: NOT STARTED  
**Dependencies**: Phases 1-4 complete  

**Steps**:

1. **Run Platform Bootstrap** (if not already done):
   ```bash
   cd EcommerceDDD-gitops
   .\scripts\bootstrap-minikube.ps1 -GitOpsRepoURL https://github.com/YOUR_ORG/EcommerceDDD-gitops
   ```

2. **Verify Platform Stack**:
   ```bash
   kubectl get pods -n platform
   kubectl get pods -n data
   kubectl logs -n platform deployment/otel-collector | grep "otlphttp exporter"
   ```

3. **Verify Aspire Dashboard**:
   ```bash
   kubectl logs -n platform deployment/aspire-dashboard | head -50
   kubectl port-forward -n platform svc/aspire-dashboard 18889:18889
   # Open http://localhost:18889 in browser
   ```

4. **Apply Apps Wave 0 (IdentityServer)**:
   ```bash
   kubectl apply -f apps/argocd/apps/dev/00-identity-server.yaml
   kubectl get application -n argocd -w
   kubectl get pods -n ecom-dev -w
   ```

5. **Monitor Sync**:
   ```bash
   argocd app get identity-server
   argocd app logs identity-server
   ```

6. **Apply Remaining Waves** (auto-sync via sync-wave annotations):
   - ArgoCD respects `sync-wave` and deploys incrementally
   - Monitor dashboard: `argocd app list -n argocd`

7. **Verify All Services Healthy**:
   ```bash
   kubectl get pods -n ecom-dev -o wide
   kubectl get svc -n ecom-dev
   kubectl describe pod <service-pod> -n ecom-dev
   ```

8. **Test End-to-End Telemetry**:
   ```bash
   # Get API Gateway service IP or port-forward
   kubectl port-forward -n ecom-dev svc/api-gateway 5000:80
   
   # Trigger a request
   curl -v http://localhost:5000/api/products
   
   # Check Aspire Dashboard
   # → Dashboard should show incoming trace with spans from all services in call chain
   ```

9. **Verify OTEL Metrics in Prometheus** (optional):
   ```bash
   kubectl port-forward -n platform svc/prometheus 9090:9090
   # Open http://localhost:9090
   # Query: ecommerceddd_* (from OTEL collector labels)
   ```

**Success Criteria**:
- ✅ All 9 service pods in `ecom-dev` namespace are Running/Ready
- ✅ Aspire Dashboard accessible via port-forward or ingress
- ✅ Aspire Dashboard shows incoming traces when API is called
- ✅ Each trace contains spans from multiple services (distributed tracing works)
- ✅ No errors in OTEL Collector, Aspire Dashboard, or service logs

---

## Rollback Plan

If Phase N fails:
1. **Phase 1 Rollback**: Edit configmap, remove `otlphttp` exporter, restart OTEL Collector
2. **Phase 2 Rollback**: Delete Aspire Dashboard Deployment + Service + Argo Application
3. **Phase 3 Rollback**: Delete Helm chart directory, no deployments affected
4. **Phase 4 Rollback**: Delete Application CRs, services terminate automatically
5. **Phase 5 Rollback**: Delete apps-dev Application CR in ArgoCD

---

## Dependencies & Assumptions

**External**:
- Docker registry with built images for all 9 services (e.g., Docker Hub, ACR)
- Minikube cluster running with sufficient resources (≥4 CPUs, 4GB RAM)
- ArgoCD already installed (done in bootstrap script)

**Internal**:
- Postgres deployed and initialized (Phase 2 of bootstrap)
- Kafka running and topics created (Phase 2 of bootstrap)
- OTEL Collector running (Phase 3 of bootstrap)
- All 9 .NET service images available in registry

**Configuration**:
- No sealed secrets needed for dev (open passwords OK)
- All services trust self-signed HTTPS certs (disabled for dev)
- Service discovery via DNS (K8s native)

---

## Timeline Estimate

| Phase | Effort | Duration |
|-------|--------|----------|
| Phase 1: OTEL Exporter Config | 30 min | 0.5h |
| Phase 2: Aspire Dashboard Deploy | 1h | 1h |
| Phase 3: Helm Chart Creation | 2h | 2h |
| Phase 4: Service Values & Apps | 1.5h | 1.5h |
| Phase 5: Deploy & Verify | 1h | 1h |
| **Total** | **5.5h** | **6h** |

---

## Success Metrics

1. **Deployment Success**: All 9 services + platform stack deployed without errors
2. **Telemetry Flow**: Aspire Dashboard shows active traces within 30 seconds of API call
3. **Observability**: Can see full distributed traces with cross-service spans
4. **Performance**: API response times < 500ms, no dropped spans
5. **Operational**: ArgoCD auto-syncs on repo changes, services auto-heal on pod failure

---

## Post-Deployment Tasks (Not in This Plan)

- [ ] Configure secrets (Postgres password, API keys) with Sealed Secrets
- [ ] Add custom Grafana dashboards for application metrics
- [ ] Set up alerting rules in Prometheus/AlertManager
- [ ] Enable HTTPS/TLS for Ingress routes
- [ ] Configure NetworkPolicies to restrict traffic between namespaces
- [ ] Document how to deploy new service versions (image tag bumping)
- [ ] Set up CI/CD pipeline to build & push service images on git push

