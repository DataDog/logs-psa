# Observability Pipelines Worker (OPW) - Best Practices Guide

**Deployment target:** 100 TB/day sustained, 200 TB/day burst (2x spike in 15 min)

**Companion file:** [`values.yaml`](./values.yaml) - production Helm values with inline sizing commentary

---

## Table of Contents

1. [Architecture](#architecture)
2. [Sizing Methodology](#sizing-methodology)
3. [Resource Configuration](#resource-configuration)
4. [Autoscaling](#autoscaling)
5. [KEDA Alternative](#keda-alternative)
6. [Buffering and Backpressure](#buffering-and-backpressure)
7. [Burst and Spike Handling](#burst-and-spike-handling)
8. [SDS Performance Optimization](#sds-performance-optimization)
9. [Monitoring and Alerting](#monitoring-and-alerting)
10. [Operational Best Practices](#operational-best-practices)
11. [Sources](#sources)

---

## Architecture

### Deployment Topology

Datadog recommends a **decentralized** deployment model: OPW instances operate in the same region/cluster/datacenter as the data sources. This minimizes cross-region transit, reduces latency, and eliminates single points of failure.

```
                           +---------------------+
                           |   Datadog Backend    |
                           | (Logs, Metrics, etc) |
                           +----------^----------+
                                      |
                                    HTTPS
                                      |
+------------------+          +-------+--------+          +------------------+
|  Sources         |   L4     |  OPW Fleet     |          |  Other Dest.     |
|  (DD Agent,      +--------->|  (StatefulSet)  +-------->|  (S3, Splunk,    |
|   OTel, Splunk)  |   NLB    |  50-100 pods    |         |   Elasticsearch) |
+------------------+          +----------------+          +------------------+
                              4 vCPU / 8 GiB each
                              55 GiB disk buffer
```

**Key architecture decisions:**

- **L4 load balancer (NLB)** in front of OPW for push-based sources. L7 (ALB) adds unnecessary overhead. Client-side load balancing is explicitly not recommended (complexity, data loss risk). ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

- **Shared-nothing architecture** - no leader election, no coordination between workers. Each pod is independent. Horizontal scaling is trivial.

- **No single instance should process more than 33% of total volume** for HA during node failure. At 50 minReplicas, each pod handles 2% - well within bounds. ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

### Deployment Approaches

https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#centralized-vs-decentralized-approach

| Approach | Description | Best For |
|---|---|---|
| **Decentralized** (recommended) | OPW per region/cluster | High volume, multi-region |
| **Centralized** | Single OPW cluster | Low volume, simple topology |
| **Hybrid** | OPW per region, not per cluster | Large deployments (6 regions, 60 clusters -> 6 OPW deployments) |

---

## Sizing Methodology

### Throughput Baselines

The conservative planning baseline is **1 TB/day per vCPU** (approximately 10 MiB/s per vCPU for ~512-byte unstructured log events).

This number comes from the [official Datadog docs](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/) and assumes a pipeline with 12 processors performing typical log transforms.

**Throughput by event type**:

https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#units-for-estimations

| Event Type | Typical Size | Per-vCPU Throughput |
|---|---|---|
| Unstructured logs | ~512 bytes | ~10 MiB/s |
| Structured logs | ~1.5 KB | ~25 MiB/s |

### Impact of SDS (Sensitive Data Scanner)

SDS is the heaviest OPW processor. Rule count and scoping dramatically affect throughput.

**Key SDS optimizations (ranked by impact):**

1. **Field scoping** - Target SDS to only PII-containing fields/services rather than scanning all fields. Can more than double throughput for high rule-count pipelines.

2. **Disable unused rules** - Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules.

3. **Rule splitting** - Split >20 SDS rules across multiple SDS processors (e.g., 40 rules into 2x20). This breaks head-of-line (HOL) blocking in OPW's Tokio FIFO task queue, where a single large SDS processor starves other pipeline tasks. At 4 vCPU with 40 unsplit rules, actual CPU utilization caps at ~2.8 vCPU because ~1.2 vCPU idles waiting for SDS. Splitting into 2x20 recovers ~3.7 vCPU (+45% throughput). Start splitting at >20 rules per processor.

4. **Pre-filter** - Filter out logs before SDS.

5. **Horizontal scaling** - Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries since each pod has an independent Tokio runtime.

### Sizing Formula

```
vCPU_needed = daily_volume_TB / throughput_per_vCPU_TB
pods_needed = vCPU_needed / vCPU_per_pod / target_utilization
```

---

## Resource Configuration

### CPU

- **4 vCPU per pod** is the sweet spot for horizontal scaling at high volume
- SDS-heavy pipelines show diminishing returns above 4 vCPU due to Tokio FIFO task queue head-of-line (HOL) blocking
- **No CPU limit** - CPU limits cause CFS throttling, which creates artificial backpressure in a CPU-bound workload
- Use **non-burstable instances** (AWS c7i/c7g, GCP c2/n2, Azure Fsv2). Burstable instances (t-family) throttle under sustained OPW load

### Memory

- **2 GiB per vCPU** minimum (docs baseline)
- Memory increases with number of destinations (each destination has in-memory batching/buffering)
- For disk-buffer-heavy deployments, some production configs use 4:1 ratio (e.g., 12 GiB for 3 vCPU)
- **Avoid unbounded cardinality in Sample/Quota processors** (grouping on `message` or other high-cardinality fields causes monotonic memory growth)
- `MALLOC_CONF="thp:never,dirty_decay_ms:1000,muzzy_decay_ms:1000"` - forces jemalloc to return pages faster after bursts (not a leak; allocator behavior)

### Disk

- Disk specs rarely matter for OPW itself (~500 MB install)
- Disk throughput matters for **disk buffer drain** scenarios: gp3 baseline is ~125 MB/s per node, shared across pods on that node
- Size PVC 10% larger than pipeline disk buffer `max_size` (OPW validates at startup)
- Structural ceiling per worker: 128 MB files * 65,536 max files = ~8 TB per disk buffer

---

## Autoscaling

### HPA (Built-in)

The `values.yaml` configures HPA with:

| Parameter | Value | Rationale |
|---|---|---|
| minReplicas | 50 | 200 vCPU at ~58% util; burst headroom |
| maxReplicas | 100 | 400 vCPU for 2x spike |
| targetCPU | 60% | Scale early; 67% burst headroom per pod |
| scaleUp stabilization | 60s | React within 1-2 min |
| scaleUp policy | +50% or +25 pods/min (Max) | Fast proportional growth |
| scaleDown stabilization | 900s (15 min) | Prevent oscillation |
| scaleDown policy | -10%/min (Min) | Slow, conservative |

A note on scaleUp policy:
- If this doesn't scale fast enough, increase to 100%.
- If this scales too fast (e.g., overshoot), reduce to 25%.
- If spikes rarely exceed 2x, consider 33% for a more gradual scale-up.
- Observe stability over time and adjust as needed for optimal cost/performance tradeoff.

**HPA Scale-Up Timeline (2x spike):**

```
T+0 min:  50 pods  (200 vCPU)  - CPU spikes above 60%, pods burst toward 100%
                                  50 pods at 100% nearly matches 2x demand (200 vCPU)
T+1 min:  75 pods  (300 vCPU)  - HPA adds 25 pods <- exceeds 2x demand at 60% target
T+2 min: 100 pods  (400 vCPU)  - HPA adds 25 pods, capped at max. Full headroom restored.
```

Demand at 2x: ~200 vCPU at 100% utilization. Fleet exceeds demand at T+1 min with headroom.

### HPA Failure Mode: SDS Backpressure

**CPU-based HPA can actively harm SDS-heavy pipelines.** When SDS saturates, CPU drops because workers idle-block waiting for the SDS processing queue. HPA interprets falling CPU as surplus capacity and **scales down** - exactly when it should scale up.

Similarly, `pipelines.utilization` (component busyness, 0-1) drops to 0 when the pipeline stalls. OPW engineering has confirmed it is "not a good indicator of backpressure, because if a buffer fills up and the pipeline stalls, every component will have a utilization of 0."

**If you use SDS with more than 10 rules, use KEDA instead of HPA.**

---

## KEDA Alternative

[KEDA](https://keda.sh/) (Kubernetes Event-Driven Autoscaling) scales based on external metrics rather than pod-level CPU/memory. It can query Datadog metrics directly using the [Datadog scaler](https://keda.sh/docs/2.16/scalers/datadog/).

### Why KEDA Over HPA for OPW

| Signal | HPA (CPU) | KEDA (Buffer Utilization) |
|---|---|---|
| SDS saturation | CPU drops -> HPA scales DOWN (wrong) | Buffer fills -> KEDA scales UP (correct) |
| Destination outage | CPU drops -> HPA scales DOWN | Buffer fills -> KEDA scales UP |
| Processing bottleneck | May scale correctly | Scales correctly |
| Normal load increase | Scales correctly | Scales correctly |

### Recommended KEDA Metrics (Ranked)

Based on analysis of all `pipelines.*` metrics across Datadog docs, Vector docs, and production incidents:

| Rank | Metric | Type | Signal | Scale Trigger |
|---|---|---|---|---|
| 1 | `pipelines.source_buffer_utilization_mean` | gauge (0-1) | Source buffer fill (EWMA-smoothed) | avg > 0.5 over 2 min |
| 2 | `pipelines.source_buffer_utilization_level` | gauge (0-1) | Instantaneous source buffer fill | avg > 0.6 |
| 3 | `kubernetes.cpu.usage` | gauge | Container CPU utilization | avg > 60% |
| 4 | `pipelines.component_discarded_events_total{intentional:false}` | count | Unintentional data loss | any non-zero = emergency |
| 5 | `pipelines.buffer_discarded_events_total{intentional:false}` | count | Buffer overflow drops | any non-zero = emergency |
| 6 | `pipelines.adaptive_concurrency_back_pressure` | histogram | ARC backpressure detection | sustained > 0 |
| 7 | `pipelines.source_lag_time_seconds` | histogram | Event freshness/lag | p95 > SLO threshold |
| 8 | `pipelines.source_send_batch_latency_seconds` | histogram | Time blocked on downstream | rising trend |

**Why `source_buffer_utilization_mean` is #1:** It is the only metric that reliably RISES during all forms of backpressure (SDS saturation, destination outage, processing bottleneck). CPU and `utilization` both DROP during stall conditions. The EWMA smoothing (configurable via `buffer_utilization_ewma_half_life_seconds`, default 5s) filters noise while remaining responsive.

**Why NOT `pipelines.utilization`:** Despite the name, this metric measures component busyness (0 = idle, 1 = never idle). Per OPW engineering: "if a buffer fills up and the pipeline stalls, every component will have a utilization of 0." It produces false negatives during the exact conditions when scaling is most needed.

### KEDA ScaledObject Manifest

Deploy this alongside OPW. Set `autoscaling.enabled: false` in the Helm values when using KEDA.

```yaml
# keda-opw-scaledobject.yaml
#
# Prerequisites:
#   1. KEDA installed: helm install keda kedacore/keda -n keda-system
#   2. Datadog API credentials in a Secret (see TriggerAuthentication below)
#   3. autoscaling.enabled: false in OPW Helm values
#
apiVersion: v1
kind: Secret
metadata:
  name: datadog-keda-secret
  namespace: observability-pipelines   # match your OPW namespace
type: Opaque
data:
  # base64-encoded Datadog API key and App key
  apiKey: <BASE64_DD_API_KEY>
  appKey: <BASE64_DD_APP_KEY>
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: datadog-auth
  namespace: observability-pipelines
spec:
  secretTargetRef:
    - parameter: apiKey
      name: datadog-keda-secret
      key: apiKey
    - parameter: appKey
      name: datadog-keda-secret
      key: appKey
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: opw-scaledobject
  namespace: observability-pipelines
spec:
  scaleTargetRef:
    # Target the OPW StatefulSet created by the Helm chart
    kind: StatefulSet
    name: opw-observability-pipelines-worker   # adjust to match your release name
  minReplicaCount: 50      # match values.yaml minReplicas
  maxReplicaCount: 100     # match values.yaml maxReplicas
  # Cooldown: 300s (5 min) after scaling before allowing scale-down.
  # Prevents oscillation during bursty traffic.
  cooldownPeriod: 300
  # Poll Datadog metrics every 15 seconds for responsive scaling.
  pollingInterval: 15
  advanced:
    # Match the HPA behavior from values.yaml for consistent scale-down
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 60
          policies:
            - type: Percent
              value: 50
              periodSeconds: 60
            - type: Pods
              value: 25
              periodSeconds: 60
          selectPolicy: Max
        scaleDown:
          stabilizationWindowSeconds: 900
          policies:
            - type: Percent
              value: 10
              periodSeconds: 60
          selectPolicy: Min
  triggers:
    # PRIMARY TRIGGER: Source buffer utilization (backpressure signal)
    # Fires when average source buffer fill exceeds 50% across workers.
    # This metric RISES during all backpressure conditions, unlike CPU.
    - type: datadog
      metadata:
        # Query: average source buffer utilization across all OPW workers
        # for this pipeline. Replace <PIPELINE_ID> with your pipeline UUID.
        query: "avg:pipelines.source_buffer_utilization_mean{pipeline_id:<PIPELINE_ID>}"
        # Scale-up threshold: 0.5 (50% buffer fill)
        # At 0.5, there's still 50% runway before the buffer is full.
        # Below 0.5 = healthy. Above 0.7 = approaching drops.
        queryValue: "0.5"
        queryAggregator: "avg"
        # Look at last 2 minutes of data for the metric query
        age: "120"
        # If metric is unavailable, assume 0 (healthy) to avoid spurious scaling
        metricUnavailableValue: "0"
      authenticationRef:
        name: datadog-auth

    # SECONDARY TRIGGER: CPU utilization (compute saturation)
    # Catches pure CPU-bound scaling needs (e.g., high event rate without SDS).
    # Uses container-level CPU metric for accuracy.
    - type: datadog
      metadata:
        query: "avg:kubernetes.cpu.usage{kube_stateful_set:opw-observability-pipelines-worker}"
        # Scale when average CPU exceeds 60% of requests (4 vCPU = 4000m, 60% = 2400m)
        # Value is in nanocores: 2,400,000,000 = 2.4 cores = 60% of 4 cores
        queryValue: "2400000000"
        queryAggregator: "avg"
        age: "120"
        metricUnavailableValue: "0"
      authenticationRef:
        name: datadog-auth

    # EMERGENCY TRIGGER: Unintentional data loss
    # Any non-zero value means events are being dropped. Scale immediately.
    - type: datadog
      metadata:
        query: "sum:pipelines.component_discarded_events_total{pipeline_id:<PIPELINE_ID>,intentional:false}.as_rate()"
        # Any value above 0 triggers scaling
        queryValue: "0"
        queryAggregator: "max"
        age: "60"
        metricUnavailableValue: "0"
      authenticationRef:
        name: datadog-auth
```

### KEDA vs HPA Decision Matrix

| Factor | Use HPA | Use KEDA |
|---|---|---|
| Pipeline has SDS | - | X |
| Pipeline has no SDS | X | X |
| Need buffer-aware scaling | - | X |
| Simplicity (fewer components) | X | - |
| Multi-signal scaling | - | X |
| Already running KEDA in cluster | - | X |
| Tight cost control (scale on leading indicators) | - | X |

---

## Buffering and Backpressure

### Buffer Chain

OPW has a three-layer buffer architecture. Only the destination buffer is user-configurable.

```
Source Buffer (non-configurable)
  |  ~1,000 events per worker thread, in-memory only
  |  Fills -> OPW returns HTTP 503 to senders
  v
Transform Buffer (non-configurable)
  |  100 events per transform, in-memory only
  |  Fills -> backpressure propagates to source
  v
Destination Buffer (user-configurable)
  |  Memory: 500 events default (min 1 MB, max 128 GB)
  |  Disk:   min ~256 MB, max 500 GB, 128 MB files, fsync every 500ms
  |  Fills -> depends on when_full policy (block or drop_newest)
  v
[Destination]
```

Source: [Buffering and Backpressure docs](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/buffering_and_backpressure/)

### Backpressure Signals

When the pipeline can't keep up, look for these indicators (in order of severity):

| Signal | Log / Metric | Severity | Meaning |
|---|---|---|---|
| Source send latency rising | `pipelines.source_send_batch_latency_seconds` | Early | Downstream processing slower than ingest |
| Source buffer filling | `pipelines.source_buffer_utilization_mean` > 0.5 | Warning | Halfway to capacity |
| "Source send cancelled" | OPW log at WARN level | High | Source producing faster than downstream consumes |
| Source buffer near full | `pipelines.source_buffer_utilization_mean` > 0.9 | Critical | About to drop events |
| Events discarded | `pipelines.component_discarded_events_total{intentional:false}` | Emergency | Data loss occurring |

### Disk Buffer Configuration

Disk buffer `max_size` and `when_full` policy are configured in the **pipeline configuration** (Terraform `datadog_observability_pipeline` resource or Datadog UI), not in Helm values. The Helm values only control the PVC size.

**Sizing formula:**

```
buffer_per_worker = throughput_per_worker * seconds_of_runway
PVC_size = buffer_per_worker * 1.10   (10% filesystem overhead)
```

**Example:**
```
At 4 vCPU, 10 MiB/s/vCPU, 20 min runway:
  buffer = 40 MB/s * 1,200s = 48,000 MB = ~47 GiB
  PVC = 47 * 1.10 = ~52 GiB -> round to 55 GiB
```

**`when_full` policies:**

| Policy | Behavior | Use When |
|---|---|---|
| `block` (default) | Backpressure propagates upstream. No data loss. | Sources have retry/buffer capability (DD Agent, OTel with persistent queue) |
| `drop_newest` | New events silently dropped. No backpressure. | Dual-shipped sources where original is preserved elsewhere (e.g., Splunk HF also sends to Splunk indexers) |

**Multi-destination fanout caveat:** If backpressure propagates from ANY destination, ALL destinations are blocked. Use `drop_newest` on non-critical destinations to isolate failures.

### Graceful Shutdown

```
terminationGracePeriodSeconds = (buffer_max_size / drain_rate) + margin
```

- Default tGPS: 70s (chart default) - almost always too low for large disk buffers
- Drain rate: network I/O bound (~50-80 MB/s for gzip-compressed sinks)
- Production reference: 3600s (1 hr) for 100 GiB buffers at ~50 TB/day

If tGPS expires, OPW logs: `"Failed to gracefully shut down in time. Killing components."` Undrained data is preserved on the PVC (via `retentionPolicy: Retain`) and resumes draining when the pod restarts.

### Orphaned PVC Problem

When HPA scales down a StatefulSet, PVCs from terminated pods become orphaned. These PVCs contain undrained disk buffer data. Without manual intervention, this data is stranded until OPWs scale back up.

**Workaround:**
1. Set `retentionPolicy.whenScaled: Retain` (data preserved)
2. Periodically identify orphaned PVCs: `kubectl get pvc -l app.kubernetes.io/name=observability-pipelines-worker | grep -v Bound`
3. Inspect buffer state before deletion

OR

Manually scale OPWs back up if data exist in buffer and allow it to drain.

---

## Burst and Spike Handling

### Strategy Overview

A 2x traffic spike (100 TB/day -> 200 TB/day) arriving within 15 minutes is handled by three layers:

```
Layer 1: HIGH minReplicas
  50 pods at 58% steady-state utilization
  Each pod has 67% burst headroom (60% -> 100%)
  50 pods at 100% nearly absorbs the full 2x spike inline

Layer 2: AGGRESSIVE HPA/KEDA scaleUp
  +50% pods per minute with 60s stabilization
  Reaches 2x capacity in ~2 minutes
  Brief sender buffering during initial saturation window

Layer 3: UPSTREAM SENDER BUFFERING
  DD Agent: retries indefinitely as long as log remains on disk
  OTel Collector: persistent queue + retry + memory_limiter
  Splunk UF: retry with tcpout
  ...
  Senders hold data locally when OPW returns HTTP 503
```

### Timeline Analysis: 2x Spike

```
T+0:00  Spike arrives. 2,315 MB/s hitting 50 pods (capacity: 2,000 MB/s at 100%)
        Each pod: 46.3 MB/s demand vs 40 MB/s capacity
        Pods burst from 58% toward 100%. Small excess causes brief 503s.
        Upstream senders begin buffering the small excess locally.
        HPA/KEDA detects high CPU / buffer fill.

T+0:30  First pods from scaleUp may start being created.

T+1:00  HPA stabilization window expires. Scaling decision: +25 pods.
        Fleet: 75 pods (capacity: 3,000 MB/s at 100%, 1,800 MB/s at 60%)
        Capacity EXCEEDS 2x demand at 60% target. Senders begin draining.

T+2:00  +25 pods, capped at max. Fleet: 100 pods (capacity: 4,000 MB/s)
        Full headroom restored. Upstream sender buffers draining.

T+3-5:  Sender buffers fully drained. System stable at ~50% utilization.

T+15:00 Spike ends. Fleet at 100 pods. scaleDown begins after 900s stabilization.

T+30:00 scaleDown removes ~10%/min. Fleet: ~66 pods.

T+45:00 Fleet: ~55 pods. Back near baseline.
```

### Upstream Sender Configuration Requirements

For the spike handling strategy to work, upstream senders MUST have retry and buffering enabled:

**OTel Collector:**
```yaml
exporters:
  otlphttp:
    endpoint: http://opw-service:8282
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage   # persistent queue
extensions:
  file_storage:
    directory: /var/lib/otelcol/queue
```

Reminder that the DD Agent retries indefinitely as long as log remains on disk.

Other collectors and shippers implement similar options.

### Burst Protection: Throttle/Quota Processor

For environments with unpredictable spikes from specific services, use the **Throttle (Quota) processor** in the OPW pipeline to rate-limit per-service:

- Group by `service` or `source` tag
- Set per-group events-per-second limits
- **Limitation:** default 1,000-bucket limit. Customers with 5,000+ services may exceed this.
- Filter (drop or sample) logs early in the pipeline (before SDS) to reduce spike amplitude

---

## SDS Performance Optimization

SDS (Sensitive Data Scanner) is the single largest performance variable in OPW pipelines. A pipeline with 40+ SDS rules scanning all fields can reduce per-vCPU throughput by 6x compared to no SDS.

### Optimization Levers (Ranked by Impact)

| Rank | Optimization | Impact | Description |
|---|---|---|---|
| 1 | **Field scoping** | +149% throughput | Target SDS to only PII-containing fields/services rather than scanning all fields. If only 14% of events contain PII, scope SDS to those services. |
| 2 | **Disable unused rules** | Varies | Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules. |
| 3 | **Rule splitting** | +45% throughput | Split >20 SDS rules across multiple SDS processors (e.g., 40 rules -> 2x20). Breaks HOL blocking in Tokio's FIFO task queue. Most impactful at 40+ rules. |
| 4 | **Horizontal scaling** | Linear | Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries. Each pod has an independent Tokio runtime. |
| 5 | **Pre-filter** | Varies | Filter out or sample logs before SDS. |

### SDS HOL Blocking Explained

OPW uses Tokio (Rust async runtime) with a FIFO task queue. When an SDS processor has many rules, each event takes longer to process. Other tasks (including other pipeline components) wait in the same queue. This is head-of-line (HOL) blocking.

At 4 vCPU with 40 unsplit SDS rules, actual CPU utilization is limited to ~2.8 vCPU because the remaining ~1.2 vCPU is idle-blocked waiting for SDS tasks.

Splitting into 2x20 SDS processors allows both to process concurrently, using ~3.7 vCPU of the 4 available (+45% throughput).

---

## Monitoring and Alerting

### OOTB Dashboard

Datadog provides an OOTB dashboard: [**"Observability Pipelines Overview"**](https://app.datadoghq.com/dash/integration/32326/observability-pipelines-overview). It covers throughput, component health, buffers, errors, CPU/memory, and SDS matches.

### Recommended Monitors

| Monitor | Metric / Condition | Severity | Rationale |
|---|---|---|---|
| **Buffer dropping data** | `pipelines.buffer_discarded_events_total{intentional:false}` > 0 | CRITICAL | Active data loss from buffer overflow |
| **Component dropping data** | `pipelines.component_discarded_events_total{intentional:false}` > 0 | CRITICAL | Active data loss from processing errors |
| **Component errors** | `pipelines.component_errors_total` > threshold | WARNING | Processing failures, potential data quality issues |
| **High CPU** | `kubernetes.cpu.usage` > 80% of request | WARNING | Approaching saturation; HPA should be scaling |
| **High memory** | `kubernetes.memory.usage_pct` > 80% of limit | WARNING | Risk of OOMKill |
| **Source buffer filling** | `pipelines.source_buffer_utilization_mean` > 0.7 | WARNING | Backpressure building, scaling may be needed |
| **Source buffer critical** | `pipelines.source_buffer_utilization_mean` > 0.9 | CRITICAL | Imminent data loss, scaling urgently needed |
| **Zero events flowing** | `pipelines.component_sent_events_total{component_kind:sink}` rate < 0.1/s for 5 min | CRITICAL | Pipeline stopped processing entirely |
| **Throughput drop** | Sent rate down >80% vs previous day | WARNING | Possible upstream or pipeline issue |
| **Pod restarts** | Restart count > 3 in 30 min | WARNING | Crash loop, likely config or resource issue |
| **Disk buffer filling** | `pipelines.data_dir_available_bytes` < 20% of `data_dir_capacity_bytes` | WARNING | Disk buffer approaching full; destination likely down |
| **HTTP client errors** | `pipelines.http_client_errors_total` > threshold | WARNING | Destination returning errors |
| **High source lag** | `pipelines.source_lag_time_seconds` p95 > threshold | WARNING | Events arriving stale; pipeline may be falling behind |

### Key Metrics Quick Reference

**Throughput:**
- `pipelines.component_received_event_bytes_total{component_kind:source}.as_rate()` - ingest bytes/s
- `pipelines.component_sent_event_bytes_total{component_kind:sink}.as_rate()` - egress bytes/s
- `pipelines.component_received_events_total{component_kind:source}.as_rate()` - ingest events/s

**Backpressure (most reliable to least):**
- `pipelines.source_buffer_utilization_mean` - EWMA source buffer fill (0-1). Best single metric.
- `pipelines.source_buffer_utilization_level` - instantaneous source buffer fill (0-1)
- `pipelines.adaptive_concurrency_back_pressure` - ARC detecting downstream slowdown
- `pipelines.source_send_batch_latency_seconds` - time blocked waiting for downstream

**Data loss:**
- `pipelines.component_discarded_events_total{intentional:false}` - unintentional drops
- `pipelines.buffer_discarded_events_total{intentional:false}` - buffer overflow drops

**Resource utilization:**
- `pipelines.cpu_usage_seconds_total` - CPU time consumed (rate = core count used)
- `pipelines.cpu_max_cores` - available cores
- `pipelines.resident_memory_used_bytes` - RSS memory
- `pipelines.data_dir_available_bytes` / `data_dir_capacity_bytes` - disk buffer space

**Per-component analysis:**
- `pipelines.utilization` by `component_id` - which component is the bottleneck (0-1)
- `pipelines.component_cpu_usage_ns_total` by `component_id` - CPU cost per processor (v2.18+)

**NOTE:** All `pipelines.*` metrics are `metric_type: count` and require `.as_rate()` or `.as_count()` in Datadog queries. Unlike `cloudprem.*` metrics (which are already rates), you must apply the rate conversion.

---

## Operational Best Practices

### Deployment

1. **Always run the latest OPW version.** Check `helm search repo datadog/observability-pipelines-worker` before every deployment. Security fixes and performance improvements ship frequently. See upgrade guide: https://docs.datadoghq.com/observability_pipelines/guide/upgrade_worker/ and helm changelog: https://github.com/DataDog/helm-charts/blob/main/charts/observability-pipelines-worker/CHANGELOG.md

2. **Pin to a specific image tag.** Don't use `latest`. Pin to a version (e.g., `2.20.4`) and upgrade deliberately.

3. **Use Helm, not kubectl.** Never create OPW resources manually via `kubectl apply`. Everything goes through Helm values for reproducibility.

4. **Dedicated node pool.** Isolate OPW from application workloads to prevent resource contention and ensure predictable performance.

### Load Balancing

- **L4 NLB only.** Do not use L7 (ALB/Ingress). OPW docs explicitly recommend L4 for performance.
- **Do NOT use client-side load balancing.** Complexity is high, and failures cause data loss.
- **Round-robin strategy.** Simple is best. OPW workers are stateless.
- **Cross-zone LB: off by default.** Enable only if traffic is measurably imbalanced across AZs.
- **Keep-alive:** 1 minute idle timeout on both clients and NLB.
- **Connection pooling:** Enable on agents/collectors if supported (reduces per-request TCP overhead).

### Memory Allocator

OPW pods may show high RSS after traffic bursts even when load returns to normal. This is jemalloc (the Rust memory allocator) retaining pages, not a memory leak.

Set in env vars:
```yaml
env:
  - name: MALLOC_CONF
    value: "thp:never,dirty_decay_ms:1000,muzzy_decay_ms:1000"
```

### Pipeline Design

- **Filter early.** Drop unwanted events (TRACE, DEBUG, health checks) as early in the pipeline as possible, before they consume SDS and transform CPU.
- **SDS: scope and split.** Target SDS to specific fields/services. Split >20 rules across multiple SDS processors.
- **Avoid high-cardinality grouping.** Sample/Quota processors grouped on `message` or other unbounded fields cause monotonic memory growth.

---

## Sources

### Datadog Official Documentation

- [Best Practices for Scaling Observability Pipelines](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/)
- [Buffering and Backpressure](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/buffering_and_backpressure/)
- [Pipeline Usage Metrics](https://docs.datadoghq.com/observability_pipelines/monitoring_and_troubleshooting/pipeline_usage_metrics/)
- [OPW Helm Chart](https://github.com/DataDog/helm-charts/tree/main/charts/observability-pipelines-worker)

### KEDA

- [Datadog Scaler](https://keda.sh/docs/2.16/scalers/datadog/)
- [Scaling Deployments](https://keda.sh/docs/2.16/concepts/scaling-deployments/)
