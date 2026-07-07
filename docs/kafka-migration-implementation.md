# Kafka Migration: Docker Compose → Minikube + Argo CD

**Date:** 2026-07-07  
**Scope:** `platform/strimzi/` in this repository  
**Source:** Replaces `confluentinc/cp-kafka:7.8.0` + `debezium/connect:2.5` from `docker-compose.infra.yml`

---

## What Was Done

Six blocking issues were identified in the existing Strimzi scaffolding and fixed.

---

### 1. Added `kafka/dev/kafka-node-pool.yaml` _(new file)_

**Why:** Strimzi requires a `KafkaNodePool` CR when the `Kafka` resource carries the annotation `strimzi.io/node-pools: enabled` (mandatory for KRaft mode in Strimzi ≥ 0.40). Without it the Kafka cluster silently never provisions — the `spec.kafka.replicas` field is ignored when node pools are enabled.

**What:** `KafkaNodePool` with combined `broker + controller` roles, 1 replica, 5 Gi PVC on the `standard` StorageClass (Minikube default), non-root security context.

---

### 2. Updated `kafka/dev/kustomization.yaml`

Added `kafka-node-pool.yaml` to the `resources` list so Argo CD applies it alongside `kafka.yaml`.

---

### 3. Rewrote `topics/dev/topics.yaml`

**Why (topic name mismatch):** The original file used `metadata.name: ecom-payments` etc. with no `spec.topicName` override. This made the actual Kafka topic names `ecom-payments`, `ecom-shipments`, `ecom-orders` — but the `.NET` `KafkaConsumer` in `OrderProcessing/appsettings.json` subscribes to `payments`, `shipments`, `orders` (no prefix). Events would never be delivered.

**Fix:** Added `spec.topicName: payments` / `shipments` / `orders` to each topic CR while keeping K8s resource names prefixed (`ecom-payments-dev` etc.).

**Why (missing Connect internal topics):** `auto.create.topics.enable: false` is set on the Kafka cluster (good operational hygiene). Kafka Connect writes its offset, config, and status data to internal topics (`CONNECT_OFFSETS`, `CONNECT_CONFIGS`, `CONNECT_STATUSES`). With auto-create disabled, Connect fails to start because those topics don't exist.

**Fix:** Added three `KafkaTopic` CRs for the Connect internal topics with `cleanup.policy: compact` (required for correctness — these are compacted topics by design).

**Topics declared after this change:**

| K8s resource name | Kafka topic name | Purpose |
|---|---|---|
| `ecom-payments-dev` | `payments` | `.NET` consumer |
| `ecom-shipments-dev` | `shipments` | `.NET` consumer |
| `ecom-orders-dev` | `orders` | `.NET` consumer |
| `connect-configs` | `CONNECT_CONFIGS` | Kafka Connect internal |
| `connect-offsets` | `CONNECT_OFFSETS` | Kafka Connect internal |
| `connect-statuses` | `CONNECT_STATUSES` | Kafka Connect internal |
| `ecom-dlq` | `ecom.dlq` | Dead-letter queue |

---

### 4. Updated `connect/dev/kafka-connect.yaml` — added `externalConfiguration`

**Why:** The `KafkaConnector` CRs reference DB credentials via `${file:/opt/kafka/external-configuration/connector-secret/username}`. Without the `externalConfiguration` block in the `KafkaConnect` spec, that path does not exist in the container and connector startup fails with a config error.

**Fix:** Added:
```yaml
externalConfiguration:
  volumes:
    - name: connector-secret
      secret:
        secretName: kafka-connector-credentials
```

This mounts the `kafka-connector-credentials` Secret at `/opt/kafka/external-configuration/connector-secret/` inside the Connect container.

**Pre-deploy step (one-time, out-of-band — do not commit to Git):**
```powershell
kubectl create secret generic kafka-connector-credentials `
  --from-literal=username=postgres `
  --from-literal=password=<POSTGRES_PASSWORD> `
  -n data
```

---

### 5. Rewrote `connect/dev/debezium-connector.yaml` — 3 connectors

**Why:** The original file had a single `KafkaConnector` CR (`ecom-outbox-connector`) targeting only `ordersdb`. Two databases (`paymentsdb`, `shipmentsdb`) had no connector. Also, the transform configuration diverged from the actual connector logic in the `.NET` codebase:

| Field | Original CR | `DebeziumConnectorSetup.BuildDebeziumConfig()` |
|---|---|---|
| `transforms.outbox.route.by.field` | `aggregatetype` | `mt_dotnet_type` |
| `transforms.outbox.route.topic.replacement` | `ecom.${routedByValue}` | service-specific lowercase string |
| `database.server.name` | `ecom-postgres` | `postgres` |
| `slot.name` / `topic.prefix` | `ecom_outbox_slot` | per-service name |

**Fix:** Replaced with 3 `KafkaConnector` CRs (`orders-connector`, `payments-connector`, `shipments-connector`) whose config exactly mirrors `DebeziumConnectorSetup.BuildDebeziumConfig()` in `EcommerceDDD.Core.Infrastructure/Outbox/DebeziumConnectorSetup.cs`:

- `transforms.outbox.route.by.field: mt_dotnet_type`
- Per-service `slot.name`, `topic.prefix`, `route.topic.replacement`
- Correct `table.include.list: public.mt_doc_outboxmessages`
- Matching converters (`StringConverter` / `JsonConverter`)
- `snapshot.mode: never`

**Connector registration strategy:** `strimzi.io/use-connector-resources: "true"` is kept on the `KafkaConnect` CR. Strimzi owns connector lifecycle. The existing `.NET` `DebeziumBackgroundWorker` will still attempt HTTP PUT on startup — this is idempotent and harmless; Strimzi reconciles back to the CR on the next cycle. The worker can be removed from the `.NET` services in a follow-up PR.

---

### 6. Fixed `operator/kustomization.yaml`

**Why:** The original patch used a JSON Patch targeting `env[0]` by index:
```yaml
- op: replace
  path: /spec/template/spec/containers/0/env/0/value
  value: "data"
```
This is fragile — if the Strimzi install YAML changes the order of environment variables in a future release, the patch silently sets the wrong variable.

Also, the resource URL pointed to `https://strimzi.io/install/latest` (floating), which means uncontrolled upgrades.

**Fix:** Replaced with a strategic merge patch targeting `STRIMZI_NAMESPACE` by name, and pinned the operator to release `0.45.0`:
```yaml
resources:
  - https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.45.0/strimzi-cluster-operator-0.45.0.yaml
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: strimzi-cluster-operator
      spec:
        template:
          spec:
            containers:
              - name: strimzi-cluster-operator
                env:
                  - name: STRIMZI_NAMESPACE
                    value: "data"
    target:
      kind: Deployment
      name: strimzi-cluster-operator
```

---

## Service ConfigMap Updates Needed

When deploying the `.NET` services, the following environment variables must be set via `ConfigMap` (not `appsettings.json`) for each Kafka-consuming service:

| Service | Setting | Value |
|---|---|---|
| OrderProcessing | `KafkaConsumer__ConnectionString` | `ecom-kafka-dev-kafka-bootstrap.data.svc.cluster.local:9092` |
| OrderProcessing | `DebeziumSettings__ConnectorUrl` | `http://ecom-connect-dev-connect-api.data.svc.cluster.local:8083/connectors/orders-connector` |
| OrderProcessing | `DebeziumSettings__DatabaseHostname` | `ecom-postgres-dev-rw.data.svc.cluster.local` |
| PaymentProcessing | `DebeziumSettings__ConnectorUrl` | `http://ecom-connect-dev-connect-api.data.svc.cluster.local:8083/connectors/payments-connector` |
| PaymentProcessing | `DebeziumSettings__DatabaseHostname` | `ecom-postgres-dev-rw.data.svc.cluster.local` |
| ShipmentProcessing | `DebeziumSettings__ConnectorUrl` | `http://ecom-connect-dev-connect-api.data.svc.cluster.local:8083/connectors/shipments-connector` |
| ShipmentProcessing | `DebeziumSettings__DatabaseHostname` | `ecom-postgres-dev-rw.data.svc.cluster.local` |

`DebeziumSettings__DatabasePassword` must come from a Kubernetes `Secret`, not a `ConfigMap`.

---

## Argo CD Sync Order (sync waves)

| Wave | Resource |
|---|---|
| 2 | Strimzi operator (in `platform` namespace, watching `data`) |
| 3 | `KafkaNodePool` + `Kafka` cluster |
| 4 | `KafkaConnect` cluster |
| 5 | `KafkaConnector` CRs (orders, payments, shipments) |
| 4 | `KafkaTopic` CRs (deployed via `platform-strimzi-topics-dev` Application) |

---

## Verification Checklist

```powershell
# 1. Strimzi operator running
kubectl get deployment strimzi-cluster-operator -n platform

# 2. Kafka cluster ready
kubectl get kafka ecom-kafka-dev -n data

# 3. Kafka node pool ready
kubectl get kafkanodepool ecom-kafka-dev -n data

# 4. Topics created
kubectl get kafkatopic -n data

# 5. KafkaConnect ready
kubectl get kafkaconnect ecom-connect-dev -n data

# 6. Connectors running
kubectl get kafkaconnector -n data

# 7. Verify connector is registered in Connect REST API
kubectl port-forward svc/ecom-connect-dev-connect-api 8083:8083 -n data
# In another terminal:
curl http://localhost:8083/connectors | ConvertFrom-Json
```

Expected connector list: `["orders-connector","payments-connector","shipments-connector"]`
