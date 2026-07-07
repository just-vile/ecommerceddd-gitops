# Kafka Migration Plan: Minikube Without Operators

**Date:** 2026-07-07  
**Scope:** Minikube dev environment only  
**Approach:** Plain Kubernetes manifests managed by Argo CD, not Kafka operators

---

## 1. Recommendation

Use plain Kubernetes manifests instead of Strimzi or other Kafka operators.

For a Minikube-only development environment, the lowest-overhead design is:
- one single-node KRaft Kafka `StatefulSet`
- one plain Kafka Connect `Deployment`
- one `Job` to create topics
- one optional Kafka UI `Deployment`
- Argo CD reconciling static YAML from the GitOps repo

This keeps the system close to the current Docker Compose setup while removing operator CRDs, reconciliation loops, and extra controller pods.

---

## 2. Context Gathered

Current Docker Compose stack uses:
- `confluentinc/cp-kafka:7.8.0` in KRaft mode with a single broker/controller node
- `debezium/connect:2.5` for Kafka Connect
- `provectuslabs/kafka-ui` for Kafka UI

Current Kafka usage in the .NET services:
- `OrderProcessing` consumes Kafka and registers Debezium connectors on startup
- `PaymentProcessing` registers a Debezium connector on startup
- `ShipmentProcessing` registers a Debezium connector on startup
- Topics in use: `payments`, `shipments`, `orders`

The services currently reference:
- `kafka:9092`
- `connect:8083`

---

## 3. Target Architecture

### Namespaces
- `data` for Kafka, Kafka Connect, Kafka UI, and topic bootstrap jobs
- `ecom-dev` for application workloads

### Services
- Kafka exposed only through an internal `ClusterIP` service
- Kafka Connect exposed only through an internal `ClusterIP` service
- Kafka UI optional for dev inspection, ideally port-forwarded only

### What is excluded
- Strimzi
- KafkaConnector CRs
- KafkaTopic CRs
- CloudNativePG operator
- Any operator-managed Kafka control plane

---

## 4. Key DNS and Config Mappings

| Current | New value |
|---|---|
| `kafka:9092` | `kafka.data.svc.cluster.local:9092` |
| `connect:8083` | `connect.data.svc.cluster.local:8083` |

Application config should continue to use env vars:
- `KafkaConsumer__ConnectionString`
- `DebeziumSettings__ConnectorUrl`
- `DebeziumSettings__DatabaseHostname`

The services should continue using the current startup-based Debezium registration flow for now, so no service code changes are required in this phase.

---

## 5. Implementation Plan

### Phase 1: Plain Kafka Manifests
1. Create a Kafka `StatefulSet` for a single-node KRaft broker/controller.
2. Add a `ConfigMap` for broker settings.
3. Add a `PersistentVolumeClaim` for Kafka data.
4. Add a `ClusterIP` service for Kafka bootstrap access.
5. Keep the configuration close to the current compose values:
   - log retention hours
   - no automatic topic creation
   - internal-only cluster access

### Phase 2: Kafka Connect as a Deployment
1. Create a plain Kafka Connect `Deployment`.
2. Point Kafka Connect to the Kafka service DNS name.
3. Mount connector credentials from a Kubernetes `Secret`.
4. Keep the Connect REST endpoint internal to the cluster.
5. Preserve the existing .NET Debezium registration path.

### Phase 3: Topic Bootstrap Job
1. Create a one-shot `Job` that creates the required topics:
   - `payments`
   - `shipments`
   - `orders`
2. Use the bootstrap job so Kafka does not need topic auto-creation enabled.
3. Run the job once during environment bootstrap or on-demand after cluster creation.

### Phase 4: Kafka UI
1. Create an optional Kafka UI `Deployment` and `Service`.
2. Use it only for development inspection.
3. Keep it out of any external ingress path unless needed.

### Phase 5: Argo CD Wiring
1. Add the Kafka manifests to the GitOps repo.
2. Register them in the Argo CD app-of-apps tree.
3. Keep them in the dev-only path.
4. Ensure Argo CD syncs the static manifests without requiring CRDs.

### Phase 6: App Config Updates
1. Update the dev environment values for the three Kafka-aware services.
2. Replace `kafka:9092` with the new in-cluster Kafka DNS name.
3. Replace `connect:8083` with the new in-cluster Kafka Connect DNS name.
4. Keep database and connector secrets out of Git.

### Phase 7: Minikube Scripts
1. Add a bootstrap script for Minikube.
2. Add a validation script for local render and manifest checks.
3. Add a teardown script if needed.

---

## 6. Files to Create or Change

### New files
- `platform/kafka/base/statefulset.yaml`
- `platform/kafka/base/service.yaml`
- `platform/kafka/base/configmap.yaml`
- `platform/kafka/base/pvc.yaml`
- `platform/kafka/bootstrap/topics-job.yaml`
- `platform/connect/deployment.yaml`
- `platform/connect/service.yaml`
- `platform/kafka-ui/deployment.yaml`
- `platform/kafka-ui/service.yaml`
- `scripts/bootstrap-minikube.ps1`
- `scripts/validate-render.ps1`

### Files to update
- `apps/environments/dev/values/order-processing.yaml`
- `apps/environments/dev/values/payment-processing.yaml`
- `apps/environments/dev/values/shipment-processing.yaml`
- Argo CD app definitions under `platform/bootstrap/argocd-apps/` if the new Kafka path needs to be registered

---

## 7. Verification Checklist

1. Kafka pods become Ready.
2. Kafka bootstrap service answers on port `9092` inside the cluster.
3. Kafka Connect starts and its REST endpoint responds inside the cluster.
4. The topic bootstrap job creates `payments`, `shipments`, and `orders`.
5. `OrderProcessing` can register its Debezium connector on startup.
6. A test message flows through Kafka and is consumed by the expected service.
7. Argo CD syncs the manifests cleanly without any operator CRDs.

---

## 8. Decisions

- Recommended approach: plain manifests first.
- Helm is optional only if templating becomes painful later.
- Keep the current Debezium startup behavior for now to avoid unnecessary service-code churn.
- Use GitOps and Argo CD for static reconciliation, but do not add Kafka operators.

---

## 9. Risks

- Manual manifest management is simpler, but less automated than an operator.
- Topic creation and configuration drift must be managed carefully with Git and bootstrap jobs.
- Kafka Connect plugin packaging may require a prebuilt image if the base image is not sufficient.
