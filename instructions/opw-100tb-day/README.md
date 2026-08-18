# Observability Pipelines Worker (OPW) - Sizing, Scaling, and Performance Guide

**Deployment target:** 100 TB/day total volume (steady state ~70 TB/day, peak ~140 TB/day, 2x peak-to-trough)

**Companion file:** [`values.yaml`](./values.yaml) - production Helm values with inline sizing commentary

---

## Table of Contents

1. [Architecture](#architecture)
2. [Sizing Methodology](#sizing-methodology)
3. [Pipeline Processing Tiers](#pipeline-processing-tiers)
4. [Deployment Sizing Table](#deployment-sizing-table)
5. [Resource Configuration](#resource-configuration)
6. [Autoscaling](#autoscaling)
7. [KEDA Alternative](#keda-alternative)
8. [Datadog Pod Autoscaler](#datadog-pod-autoscaler)
9. [Buffering and Backpressure](#buffering-and-backpressure)
10. [Burst and Spike Handling](#burst-and-spike-handling)
11. [SDS Performance Optimization](#sds-performance-optimization)
12. [Kubernetes Deployment](#kubernetes-deployment)
13. [VM Deployment](#vm-deployment)
14. [Monitoring and Alerting](#monitoring-and-alerting)
15. [Operational Best Practices](#operational-best-practices)
16. [Best Practices Checklist](#best-practices-checklist)
17. [Sources](#sources)

---

## Architecture

### Deployment Topology

Datadog recommends a **decentralized** deployment model: OPW instances operate in the same region/cluster/datacenter as the data sources. This minimizes cross-region transit, reduces latency, and eliminates single points of failure.

```
                           +----------------------+
                           |   Datadog Backend    |
                           | (Logs, Metrics, etc) |
                           +----------^-----------+
                                      |
                                    HTTPS
                                      |
+------------------+          +-------+--------+          +------------------+
|  Sources         |   L4     |  OPW Fleet     |          |  Other Dest.     |
|  (DD Agent,      +--------->|  (StatefulSet)  +-------->|  (S3, Splunk,    |
|   OTel, Splunk)  |   NLB    |  40-80 pods    |          |   Elasticsearch) |
+------------------+          +----------------+          +------------------+
                              3.5 vCPU / 7 GiB each
                              55 GiB disk buffer
```

**Key architecture decisions:**

- **L4 load balancer (NLB)** in front of OPW for push-based sources. L7 (ALB) adds unnecessary overhead. Client-side load balancing is explicitly not recommended (complexity, data loss risk). ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

- **Shared-nothing architecture** - no leader election, no coordination between workers. Each pod is independent. Horizontal scaling is trivial.

- **No single instance should process more than 33% of total volume** for HA during node failure. At 40 minReplicas, each pod handles 2.5% - well within bounds. ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

### Deployment Approaches

[Official docs reference](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#centralized-vs-decentralized-approach)

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

**Always start with the 1 TB/vCPU/day formula.** This is conservative, and pipeline complexity can exceed the tiers tested. Oversize initially, monitor performance using self-reported OPW metrics, and optimize after observing the system.

**Throughput by event type:**

| Event Type | Typical Size | Per-vCPU Throughput |
|---|---|---|
| Unstructured logs | ~512 bytes | ~10 MiB/s |
| Structured logs | ~1.5 KB | ~25 MiB/s |

Source: [Scaling documentation](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#units-for-estimations)

### Impact of SDS (Sensitive Data Scanner)

SDS is the heaviest OPW processor. Rule count and scoping dramatically affect throughput.

**Key SDS optimizations (ranked by impact):**

1. **Field scoping** - Target SDS to only PII-containing fields/services rather than scanning all fields. Can more than double throughput for high rule-count pipelines (+149% at 40 rules).

2. **Disable unused rules** - Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules.

3. **Rule splitting** - Split >20 SDS rules across multiple SDS processors (e.g., 40 rules into 2x20). This breaks head-of-line (HOL) blocking in OPW's Tokio FIFO task queue, where a single large SDS processor starves other pipeline tasks. At 4 vCPU with 40 unsplit rules, actual CPU utilization caps at ~2.8 vCPU because ~1.2 vCPU idles waiting for SDS. Splitting into 2x20 recovers ~3.7 vCPU (+45% throughput). Start splitting at >20 rules per processor.

4. **Pre-filter** - Filter out logs before SDS. Place volume-reduction processors (filter, sample, throttle, quota, dedupe) before SDS.

5. **Horizontal scaling** - Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries since each pod has an independent Tokio runtime.

### Sizing Formula

```
Required vCPU = (daily volume in TB) / (TB per vCPU per day for your tier)
Required pods = ceil(Required vCPU / vCPU per pod)
```

Add 25% headroom above the baseline. Always enable autoscaling. Set the HPA maximum to 2x the baseline to absorb daily fluctuations and spikes.

### Event Size Matters

The benchmarks in this guide used a heterogeneous workload averaging approximately 2,127 bytes per event. Throughput in bytes per second is relatively stable across event sizes, but throughput in events per second varies. If your events are smaller (under 512 bytes), expect higher events-per-second rates at similar bytes-per-second throughput. If your events are larger (over 4 KB), expect lower events-per-second rates.

---

## Pipeline Processing Tiers

We tested three representative pipeline tiers, each progressively more compute-intensive. The results establish concrete throughput baselines per vCPU.

### Basic Processing

A pipeline focused on routing, filtering, sampling, and field manipulation. No SDS. No custom VRL.

**Processors:** filter, sample, add fields, JSON parse, rename fields, grok parse (nginx CLF pattern), remove fields, reduce (aggregation on a specific service), tag enrichment.

### Medium Processing + SDS

Extends Basic Processing with Sensitive Data Scanner, metrics generation, and deduplication.

**Additional processors:** SDS with 10 credit card detection rules, generate metrics, and dedupe.

Tested in two configurations:
- **Targeted SDS:** SDS scans only services that handle sensitive data (~20% of events). Recommended.
- **Blanket SDS:** SDS scans every event. Significant performance cost.

### Heavy Processing + SDS

Extends Medium Processing with a larger SDS rule set (40 rules), CPU-intensive VRL transforms, and additional enrichment.

### Throughput Per vCPU

All results measured at ~1 vCPU on AWS EKS with c7a.2xlarge instances (AMD EPYC Genoa). Test workload: eight event types, weighted average ~2,127 bytes per event, sustained over 15-minute steady-state windows.

| Pipeline Tier | TB/day per vCPU | Events/s | MB/s | CPU (1 Pod) | Memory (RSS) |
|---|---|---|---|---|---|
| Basic Processing | 4.70 | 26,734 | 45.6 | 0.84 | 159 MB |
| Medium + SDS, targeted (10 rules) | 3.61 | 19,087 | 40.6 | 0.97 | 228 MB |
| Medium + SDS, blanket (10 rules) | 2.95 | 15,300 | 32.5 | 0.95 | 220 MB |
| Heavy + SDS, targeted (40 rules) | 1.97 | 10,635 | 22.6 | 0.99 | 234 MB |
| Heavy + SDS, blanket (40 rules) | 0.79 | 4,288 | 9.1 | 1.00 | 226 MB |

### The Cost of Blanket Scanning

Blanket scanning with 40 rules consumes 83% of the throughput available to a no-SDS pipeline. A pipeline that processes 100 TB/day at the Basic tier would need over 6x the compute to handle the same volume with 40-rule blanket SDS.

| Pipeline Configuration | TB/day per vCPU | vs Basic |
|---|---|---|
| Basic Processing (no SDS) | 4.70 | baseline |
| Medium + SDS, targeted (10 rules, 14% of events) | 3.61 | -23% |
| Medium + SDS, blanket (10 rules, all events) | 2.95 | -37% |
| Heavy + SDS, targeted (40 rules, 14% of events) | 1.97 | -58% |
| Heavy + SDS, blanket (40 rules, all events) | 0.79 | -83% |

---

## Deployment Sizing Table

These are **minimums** assuming **targeted SDS scanning** with **25% capacity headroom**. Weighted toward the conservative 1 vCPU per 1 TB/day baseline. Always enable autoscaling with max = 2x baseline.

A configuration such as **5 x 2 vCPU** means **five workers, each allocated 2 vCPUs**.

| Daily Volume | Basic Processing | Medium + SDS (targeted) | Heavy + SDS (targeted) |
|---|---|---|---|
| 5 TB/day | 3 x 1 vCPU | 5 x 1 vCPU | 4 x 2 vCPU |
| 10 TB/day | 3 x 2 vCPU | 5 x 2 vCPU | 6 x 3 vCPU |
| 50 TB/day | 10 x 3 vCPU | 17 x 3 vCPU | 30 x 3 vCPU |
| **100 TB/day** | **20 x 3 vCPU** | **34 x 3 vCPU** | **60 x 3 vCPU** |

**If your pipeline uses blanket SDS scanning,** multiply the Heavy + SDS pod count by approximately 2.5x.

---

## Resource Configuration

### CPU

- **3.5 vCPU per pod** for efficient binpacking on 8-vCPU nodes (2 x 3.5 = 7.0 vCPU, leaving 1.0 for kubelet/DaemonSets/OS). At `cpu: "4"`, Kubernetes cannot fit 2 pods on an 8-vCPU node after accounting for kubelet reservations and DaemonSets.
- SDS-heavy pipelines show diminishing returns above 3-4 vCPU due to Tokio FIFO task queue head-of-line (HOL) blocking
- **No CPU limit** - CPU limits cause CFS throttling, which creates artificial backpressure in a CPU-bound workload. The official OPW Helm chart intentionally omits CPU limits.
- Use **non-burstable instances** (AWS c7i/c7g, GCP c2/c4a, Azure Fsv2). Burstable instances (AWS t-family, Azure B-series, GCP e2) throttle under sustained OPW load.

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
| minReplicas | 40 | 140 vCPU; handles 70 TB/day steady state at 50% util |
| maxReplicas | 80 | 280 vCPU; handles 140 TB/day peak at 50% util |
| targetCPU | 60% | Scale early; 67% burst headroom per pod |
| scaleUp stabilization | 60s | React within 1-2 min |
| scaleUp policy | +50% or +20 pods/min (Max) | Fast proportional growth |
| scaleDown stabilization | 900s (15 min) | Prevent oscillation |
| scaleDown policy | -10%/min (Min) | Slow, conservative |

A note on scaleUp policy:
- If this doesn't scale fast enough, increase to 100%.
- If this scales too fast (e.g., overshoot), reduce to 25%.
- If spikes rarely exceed 2x, consider 33% for a more gradual scale-up.
- Observe stability over time and adjust as needed for optimal cost/performance tradeoff.

**HPA Scale-Up Timeline (steady state to peak):**

```
T+0 min:  40 pods  (140 vCPU)  - Peak traffic ramps. CPU rises above 60%.
                                  40 pods at 100% = 140 vCPU, matches peak demand exactly.
T+1 min:  60 pods  (210 vCPU)  - HPA adds 20 pods. Exceeds peak demand at 60% target.
T+2 min:  80 pods  (280 vCPU)  - HPA adds 20 pods, capped at max. Full headroom restored.
```

Peak demand: 140 vCPU at 100% utilization. Fleet exceeds demand at T+1 min.

### HPA Failure Mode: SDS Backpressure

**CPU-based HPA can actively harm SDS-heavy pipelines.** When SDS saturates, CPU drops because workers idle-block waiting for the SDS processing queue. HPA interprets falling CPU as surplus capacity and **scales down** - exactly when it should scale up.

Similarly, `pipelines.utilization` (component busyness, 0-1) drops to 0 when the pipeline stalls. OPW engineering has confirmed it is "not a good indicator of backpressure, because if a buffer fills up and the pipeline stalls, every component will have a utilization of 0."

**If you use SDS with more than 20 rules, use KEDA or DPA instead of HPA.**

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

| Rank | Metric | Signal | Scale Trigger |
|---|---|---|---|
| 1 | `pipelines.source_buffer_utilization_mean` | Source buffer fill (EWMA) | avg > 50% of capacity for 2 min |
| 2 | `kubernetes.cpu.usage` | Container CPU | avg > 60% |
| 3 | `pipelines.component_discarded_events_total{intentional:false}` | Unintentional data loss | any non-zero = emergency |

**Why `source_buffer_utilization_mean` is #1:** It is the only metric that reliably RISES during all forms of backpressure (SDS saturation, destination outage, processing bottleneck). CPU and `utilization` both DROP during stall conditions. The EWMA smoothing (configurable via `buffer_utilization_ewma_half_life_seconds`, default 5s) filters noise while remaining responsive.

**IMPORTANT:** `source_buffer_utilization_mean` reports **raw event counts, not a 0-1 ratio**. Maximum value = vCPU x 1,000 (e.g., 3,500 for a 3.5-vCPU pod). Set KEDA thresholds as absolute values. For a 3.5-vCPU pod, 50% of capacity = 1,750.

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
  minReplicaCount: 40      # match values.yaml minReplicas
  maxReplicaCount: 80      # match values.yaml maxReplicas
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
              value: 20
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
    # This metric RISES during all backpressure conditions, unlike CPU.
    #
    # IMPORTANT: source_buffer_utilization_mean reports RAW EVENT COUNTS,
    # not a 0-1 ratio. Max value = vCPU x 1,000.
    # For 3.5-vCPU pods: max capacity = 3,500, 50% = 1,750.
    # Adjust queryValue when changing pod vCPU size.
    - type: datadog
      metadata:
        query: "avg:pipelines.source_buffer_utilization_mean{pipeline_id:<PIPELINE_ID>}"
        queryValue: "1750"
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
        # Scale when average CPU exceeds 60% of requests (3.5 vCPU = 3500m, 60% = 2100m)
        # Value is in nanocores: 2,100,000,000 = 2.1 cores = 60% of 3.5 cores
        queryValue: "2100000000"
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

| Factor | Use HPA | Use KEDA/DPA |
|---|---|---|
| Pipeline has no SDS or fewer than 20 rules | X | X |
| Pipeline has 20+ SDS rules | - | X |
| Need buffer-aware scaling | - | X |
| Simplicity (fewer components) | X | - |
| Multi-signal scaling | - | X |
| Already running KEDA in cluster | - | X |
| Tight cost control (scale on leading indicators) | - | X |

---

## Datadog Pod Autoscaler

The [Datadog Pod Autoscaler](https://www.datadoghq.com/architecture/kubernetes-workload-autoscaling-with-datadog/) (DPA) is a Kubernetes-native autoscaler that queries Datadog metrics directly, without requiring KEDA as an intermediary. DPA uses the Datadog Cluster Agent to evaluate scaling rules against any metric in your Datadog account.

For OPW, DPA can scale on the same pipeline-aware metrics recommended for KEDA (`source_buffer_utilization_mean`, CPU, discarded events) but with a simpler operational footprint: no KEDA installation, no separate TriggerAuthentication secrets, and native integration with the Datadog Cluster Agent you may already be running.

At scale, even small efficiency improvements from better autoscaling have real cost impact. A fleet of 80 OPW pods on c7i.2xlarge instances (~$260/month each, shared 2 pods/node = 40 nodes) where a 5% reduction in average pod count saves approximately $520/month (2 fewer nodes).

**Status:** DPA is a newer option. Evaluate whether it meets your scaling precision requirements alongside KEDA.

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

`source_buffer_utilization_mean` reports **raw event counts** (max = vCPU x 1,000), not a 0-1 ratio. The thresholds below are expressed as percentages of capacity.

| Signal | Log / Metric | Severity | Meaning |
|---|---|---|---|
| Source send latency rising | `pipelines.source_send_batch_latency_seconds` | Early | Downstream processing slower than ingest |
| Source buffer filling | `source_buffer_utilization_mean` > 50% of capacity | Warning | Halfway to capacity |
| "Source send cancelled" | OPW log at WARN level | High | Source producing faster than downstream consumes |
| Source buffer near full | `source_buffer_utilization_mean` > 90% of capacity | Critical | About to drop events |
| Events discarded | `pipelines.component_discarded_events_total{intentional:false}` | Emergency | Data loss occurring |

### Disk Buffer Configuration

Disk buffer `max_size` and `when_full` policy are configured in the **pipeline configuration** (Terraform `datadog_observability_pipeline` resource or Datadog UI), not in Helm values. The Helm values only control the PVC size.

**Sizing formula:**

```
buffer_per_worker = throughput_per_vCPU x vCPU x buffer_duration_seconds
PVC_size = buffer_per_worker x 1.10   (10% filesystem overhead)
```

**Example:**
```
At 3.5 vCPU, 10 MiB/s/vCPU, 20 min runway:
  buffer = 35 MB/s * 1,200s = 42,000 MB = ~41 GiB
  PVC = 41 * 1.10 = ~45 GiB -> round to 55 GiB (extra runway)
```

**Disk buffer limits:** Minimum 256 MB, maximum 500 GB. On-disk format uses 128 MB data files with fsync every 500 ms. Data written within the last 500 ms is at risk on an unexpected crash.

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

Daily traffic follows a diurnal pattern: ~57% of the day at steady state (70 TB/day rate), ~43% at peak (140 TB/day rate), averaging to 100 TB/day total. The peak transition is handled by three layers:

```
Layer 1: HIGH minReplicas
  40 pods at 50% steady-state utilization
  Each pod has ~67% burst headroom (60% -> 100%)
  40 pods at 100% = 140 vCPU, matches peak demand exactly

Layer 2: AGGRESSIVE HPA/KEDA scaleUp
  +50% pods per minute with 60s stabilization
  Reaches peak capacity in ~2 minutes

Layer 3: UPSTREAM SENDER BUFFERING
  DD Agent: retries indefinitely as long as log remains on disk
  OTel Collector: persistent queue + retry + memory_limiter
  Splunk UF: retry with tcpout
  ...
  Senders hold data locally when OPW returns HTTP 503
```

### Timeline Analysis: Steady State to Peak

```
T+0:00  Peak traffic ramps. 1,620 MB/s hitting 40 pods (capacity: 1,400 MB/s at 100%)
        Each pod: 40.5 MB/s demand vs 35 MB/s capacity
        Pods burst from 50% toward 100%. Small excess causes brief 503s.
        Upstream senders begin buffering the small excess locally.
        HPA/KEDA detects high CPU / buffer fill.

T+0:30  First pods from scaleUp may start being created.

T+1:00  HPA stabilization window expires. Scaling decision: +20 pods.
        Fleet: 60 pods (capacity: 2,100 MB/s at 100%, 1,260 MB/s at 60%)
        Capacity EXCEEDS peak demand at 60% target. Senders begin draining.

T+2:00  +20 pods, capped at max. Fleet: 80 pods (capacity: 2,800 MB/s)
        Full headroom restored. Upstream sender buffers draining.

T+3-5:  Sender buffers fully drained. System stable at 50% utilization.

        [Peak period: ~10 hours at 140 TB/day rate]

T+end:  Peak subsides. scaleDown begins after 900s stabilization.
        scaleDown removes ~10%/min. Fleet: 80 -> 72 -> 65 -> ...
        Back to 40 pods within ~45 min.
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

SDS (Sensitive Data Scanner) is the single largest performance variable in OPW pipelines. Understanding how it behaves and how to configure it efficiently can mean the difference between 0.79 TB and 4.7 TB per vCPU per day.

### How SDS Affects Throughput

SDS evaluates regex rules against every scannable field of every event it processes. Cost scales with three factors:

1. **Number of rules:** Each additional 25 rules reduces maximum throughput by approximately 30-40%. This is the dominant cost driver.
2. **Number of fields per event:** Cost scales linearly with field count. Events with 100 fields take roughly 3x longer to scan than events with 30 fields.
3. **Field value size:** Cost scales logarithmically with byte length. Doubling the field size does not double the scan time.

The following have **no measurable effect** on scan time: redaction method, match action type, key name size, and nesting depth.

### Optimization Levers (Ranked by Impact)

| Rank | Optimization | Impact | Description |
|---|---|---|---|
| 1 | **Field/service scoping** | +149% throughput | Target SDS to only PII-containing fields/services. If only 14% of events contain PII, scope SDS to those services. |
| 2 | **Disable unused rules** | Varies | Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules. |
| 3 | **Rule splitting** | +45% throughput | Split >20 SDS rules across multiple SDS processors (e.g., 40 rules -> 2x20). Breaks HOL blocking in Tokio's FIFO task queue. Most impactful at 40+ rules. |
| 4 | **Horizontal scaling** | Linear | Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries. Each pod has an independent Tokio runtime. |
| 5 | **Pre-filter** | Varies | Filter out or sample logs before SDS. Place volume-reduction processors before SDS. |

### SDS Scoping: Targeted vs Blanket

| SDS Rules | Blanket (all events) | Targeted (20% of events) | Improvement |
|---|---|---|---|
| 10 rules | 2.95 TB/day/vCPU | 3.61 TB/day/vCPU | +22% |
| 40 rules | 0.79 TB/day/vCPU | 1.97 TB/day/vCPU | +149% (2.5x) |

### Rule Splitting: Before and After

At 4 vCPU with 40 rules:

| Metric | Unsplit (1x40 rules) | Split (2x20 rules) | Delta |
|---|---|---|---|
| Total throughput | 3.57 TB/day | 5.18 TB/day | +45% |
| Events/s | 19,414 | 28,169 | +45% |
| Bytes/s | 39.4 MB/s | 59.9 MB/s | +52% |
| vCPU consumed (of 4 allocated) | 2.82 | 3.65 | +29% |
| Per-vCPU efficiency | 1.26 TB/day/vCPU | 1.42 TB/day/vCPU | +12% |
| Memory RSS | ~234 MB | ~253 MB | +19 MB |

The unsplit configuration left 1.18 vCPU idle due to HOL blocking. Splitting broke through that ceiling.

### Splitting vs Horizontal Scaling

| Configuration (4 vCPU total, Heavy + SDS) | Total Throughput | vs unsplit 1x4 |
|---|---|---|
| 1 pod x 4 vCPU, unsplit (1x40 rules) | 3.57 TB/day | baseline |
| 1 pod x 4 vCPU, split (2x20 rules) | 5.18 TB/day | +45% |
| 4 pods x 1 vCPU, unsplit | 6.04 TB/day | +69% |

Horizontal scaling delivers the best total throughput. Splitting is valuable when you cannot easily add pods.

### When Splitting Helps

- **At 1 vCPU per pod:** No effect (HOL blocking requires multiple threads)
- **At 2 vCPU with 10 rules:** Moderate benefit (+16%)
- **At 3-4 vCPU with 40+ rules:** Strongly recommended (+45%)
- **Under moderate load (70-80% CPU):** Smaller benefit; most impactful at capacity

Customer validation: "We split our single SDS into 6 with less than 20 rules each. We got significant improvement on the max pipelines utilization, about 50%."

### Throughput Degradation at High Rule Counts

| Active SDS Rules | Relative Throughput (vs 25-rule baseline) |
|---|---|
| 25 | 1.00x |
| 50 | 0.65x |
| 75 | 0.45x |
| 100 | 0.33x |
| 150 | 0.23x |

Empirical formula:

```
throughput_per_vCPU = baseline x (0.65) ^ (rule_count / 25)
```

Where `baseline` is approximately 1.0-1.2 TB per vCPU per day at 0-10 rules.

### Auditing Rules

1. Query `pipelines.sds_rule_matched_total` over a 30-day rolling window grouped by rule name.
2. Rules with zero matches over 30 days are strong candidates for removal. Rules with fewer than 10 matches warrant manual review.
3. Re-audit quarterly.

### Case Study: SDS Saturation and Autoscaler Failure

A customer running 187 SDS rules across 400 OPW pods experienced HPA scaling DOWN during a deployment-induced log spike because CPU dropped during SDS saturation. Total throughput dropped 60%, source buffers filled.

The customer's observation: "CPU usage was down since the pipeline was blocked on SDS which resulted in the HPA actually scaling down the pipeline during this time. Probably the opposite of what we would have wanted."

**Recommendations:**
- Audit rule necessity: 187 rules is significantly more than most organizations need.
- Filter which events SDS scans.
- Limit which fields SDS scans.
- Split rules across multiple SDS processors (with 187 rules, split to 8-10 processors of ~20 rules each).
- Replace CPU-based HPA with KEDA/DPA scaling on `source_buffer_utilization_mean`.

---

## Kubernetes Deployment

### Instance Selection

Use compute-optimized, non-burstable instances with at least 8 vCPU per node:

| Cloud | Recommended Instance Types |
|---|---|
| AWS | c7i.2xlarge, c7a.2xlarge, c7g.2xlarge (Graviton) |
| Azure | F8s v2, F16s v2, E8ps_v6 (Cobalt) |
| GCP | c2-standard-8, c2-standard-16, c4a-standard-8 (Axion) |

Avoid burstable instances (AWS t-family, Azure B-series, GCP e2). OPW under sustained load will exhaust CPU credits and throttle.

### Pod Scheduling

- **Pod anti-affinity:** Soft preference for one OPW pod per node. One node failure = one pod lost, not all.
- **Topology spread:** Pods spread across AZs with `maxSkew: 2`. Remove if single-AZ cluster.
  - **Cost note:** Multi-AZ topology spread means cross-zone traffic. AWS charges ~$0.01/GB for cross-AZ within region. GCP does not charge. Azure varies. At high log volumes, this cost can be meaningful.
- **Pod disruption budget:** `maxUnavailable: 10%` - at 40 pods = 4 can be disrupted at once.
- **Pod management policy:** `Parallel` for fast HPA scale-up. `OrderedReady` is too slow for traffic spikes.
- **Update strategy:** `RollingUpdate` with `maxUnavailable: 10%`.

### Karpenter and Node Provisioning

OPW is compatible with [Karpenter](https://karpenter.sh/) for dynamic node provisioning:

- **PVC zone affinity:** OPW StatefulSet PVCs are zone-bound (ReadWriteOnce). Karpenter nodes must be in the same AZ as existing PVCs.
- **Instance selection:** Constrain to compute-optimized families, exclude burstable types:

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: ["c7i", "c7g", "c7a"]
  - key: karpenter.k8s.aws/instance-size
    operator: In
    values: ["xlarge", "2xlarge"]
```

- **Consolidation:** Karpenter's consolidation may pack pods onto fewer nodes during low-traffic periods. Generally safe given shared-nothing architecture, but can conflict with pod anti-affinity preferences.

### High Availability

Always deploy at least three OPW pods. In HA testing, killing one pod in a three-replica deployment resulted in zero events dropped, with surviving pods absorbing full load within 36 seconds.

---

## VM Deployment

### Instance Sizing

Use compute-optimized instances. OPW is CPU-bound, and memory consumption is modest.

| Cloud | Minimum | Recommended |
|---|---|---|
| AWS | c7i.xlarge (4 vCPU, 8 GB) | c7i.2xlarge (8 vCPU, 16 GB) |
| Azure | F4s v2 (4 vCPU, 8 GB) | F8s v2 (8 vCPU, 16 GB) |
| GCP | c2-standard-4 (4 vCPU, 16 GB) | c2-standard-8 (8 vCPU, 32 GB) |

### Instance Group and Autoscaling

Deploy OPW in a managed instance group (AWS ASG, GCP MIG, Azure VMSS) behind a network load balancer (L4). Do not use an application load balancer (L7).

- **Scale up at 70% average CPU.** For SDS-heavy pipelines, lower to 50-60%.
- **Minimum 3 instances** for high availability.
- **Cap individual instances at 50% of total pipeline volume.**
- **Enable the OP API** for health checks: `DD_OP_API_ENABLED=true` and `DD_OP_API_ADDRESS=0.0.0.0:8686`.

### Network Requirements

OPW requires outbound HTTPS (port 443) to these Datadog domains:

- `api.<DD_SITE>` - API key and pipeline ID validation
- `config.<DD_SITE>` - Remote Configuration delivery (polled every 5 seconds)
- `http-intake.logs.<DD_SITE>` - OPW operational logs
- `*.agent.<DD_SITE>` - Metrics (subdomain changes per version)
- `obpipeline-intake.<DD_SITE>` - Live Capture

See [Network traffic configuration](https://docs.datadoghq.com/observability_pipelines/configuration/network_traffic) for the complete domain list.

---

## Monitoring and Alerting

### OOTB Dashboard

Datadog provides an OOTB dashboard: **Observability Pipelines Overview**. It covers throughput, component health, buffers, errors, CPU/memory, and SDS matches. No configuration required.

### Recommended Monitors

| Severity | Metric | Condition | Description |
|---|---|---|---|
| Critical | `component_discarded_events_total{intentional:false}` | > 0 | Active unintentional data loss |
| Critical | `buffer_discarded_events_total{intentional:false}` | > 0 | Buffer overflow data loss |
| Critical | `source_buffer_utilization_mean` | > 90% of capacity for 5 min | Imminent source-level data loss |
| Critical | `component_sent_events_total{component_kind:sink}` | < 0.1/s for 5 min | Zero events flowing to destination |
| Warning | `cpu_usage_seconds_total` (as rate) | > 80% of requests | Approaching CPU capacity |
| Warning | `resident_memory_used_bytes` | > 80% of limits | Approaching memory limit |
| Warning | `source_buffer_utilization_mean` | > 70% of capacity for 5 min | Early backpressure warning |
| Warning | `utilization{component_type:sensitive_data_scanner}` | > 0.9 sustained | SDS is the pipeline bottleneck |
| Warning | `container.cpu.throttled` | > 0 | Remove CPU limit if set |
| Warning | `component_errors_total` | > 0 | Processing errors |
| Warning | Pod restarts | > 3 in 30 min | Instability |
| Warning | `data_dir_available_bytes` | < 20% of capacity | Disk buffer filling |
| Warning | `http_client_errors_total` | > threshold | Destination returning errors |
| Warning | `source_lag_time_seconds` p95 | > SLO threshold | Events arriving stale |

### Key Metrics Quick Reference

**Throughput:**
- `pipelines.component_received_event_bytes_total{component_kind:source}.as_rate()` - ingest bytes/s (primary sizing validation)
- `pipelines.component_sent_event_bytes_total{component_kind:sink}.as_rate()` - egress bytes/s
- `pipelines.component_received_events_total{component_kind:source}.as_rate()` - ingest events/s

**Backpressure (most reliable to least):**
- `pipelines.source_buffer_utilization_mean` - EWMA source buffer fill. Best single metric. Reports **raw event counts** (max = vCPU x 1,000), not 0-1.
- `pipelines.source_lag_time_seconds` (distribution) - event freshness/lag (OPW 2.16+)
- `pipelines.buffer_size_events` / `buffer_size_bytes` - destination buffer fill level
- `pipelines.source_send_batch_latency_seconds` - time blocked waiting for downstream

**Data loss:**
- `pipelines.component_discarded_events_total{intentional:false}` - unintentional drops
- `pipelines.buffer_discarded_events_total{intentional:false}` - buffer overflow drops

**Resource utilization:**
- `pipelines.cpu_usage_seconds_total` - CPU time consumed (rate = core count used)
- `pipelines.resident_memory_used_bytes` - RSS memory
- `container.cpu.throttled` - must be zero
- `pipelines.data_dir_available_bytes` / `data_dir_capacity_bytes` - disk buffer space

**SDS-specific:**
- `pipelines.utilization{component_type:sensitive_data_scanner}` - SDS saturation (0-1). Sustained > 0.9 = bottleneck. Note: drops to 0 during stalls - do NOT use as autoscaling signal.
- `pipelines.component_latency_seconds{component_type:sensitive_data_scanner}` (distribution) - per-event SDS processing time. Enable percentiles in Metrics Summary before querying.
- `pipelines.sds_rule_matched_total` - match counts per rule (for auditing)

**Per-component analysis:**
- `pipelines.utilization` by `component_id` - which component is the bottleneck (0-1)
- `pipelines.component_cpu_usage_ns_total` by `component_id` - CPU cost per processor (v2.18+)

**NOTE:** All `pipelines.*` metrics are `metric_type: count` and require `.as_rate()` or `.as_count()` in Datadog queries.

---

## Operational Best Practices

### Deployment

1. **Always run the latest OPW version.** Check `helm search repo datadog/observability-pipelines-worker` before every deployment. See upgrade guide: https://docs.datadoghq.com/observability_pipelines/guide/upgrade_worker/

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

## Best Practices Checklist

**Sizing:**
- Start with the conservative 1 TB/vCPU/day estimate, observe, then size for your actual pipeline tier
- Add 25% headroom above calculated vCPU requirements
- Cap pods at 4 vCPU; scale horizontally when more capacity is needed
- Budget 2 GiB memory per vCPU

**SDS optimization:**
- Scope SDS to only the services that handle sensitive data
- Limit which fields SDS scans to reduce per-event regex work
- Audit enabled rules routinely over 30-day windows; disable rules with zero matches
- Split rule sets larger than 20 rules across multiple SDS processors
- Place SDS after volume reduction processors when pipeline ordering permits
- Use `pipelines.component_latency_seconds{component_type:sensitive_data_scanner}` to measure optimization impact

**Deployment:**
- Always deploy at least 3 replicas for high availability
- Do not set CPU limits on OPW pods
- Use compute-optimized, non-burstable instance types
- Use L4 network load balancers, not L7 application load balancers
- Enable PodDisruptionBudget, pod anti-affinity, and topology spread constraints
- Allowlist required Datadog domains for outbound HTTPS (port 443) if network restricts egress

**Autoscaling:**
- Use CPU-based HPA at 60% target for standard pipelines (no SDS or <20 rules)
- Use KEDA or DPA with `source_buffer_utilization_mean` for SDS-heavy pipelines (20+ rules)
- Configure aggressive scale-up (react in 1-2 min) and conservative scale-down (15-min stabilization)
- Set max replicas to 2x baseline for burst absorption

**Buffering:**
- Use disk buffers when data durability during destination outages matters
- Set `when_full: drop_newest` on non-critical destination buffers to prevent multi-destination blocking
- Set `terminationGracePeriodSeconds` to cover your maximum buffer drain time

**Monitoring:**
- Alert on `component_discarded_events_total{intentional:false}` (critical: any non-zero)
- Alert on `source_buffer_utilization_mean` (warning at 70% of capacity, critical at 90%); this metric reports raw event counts (max = vCPU x 1,000), not 0-1
- Monitor SDS utilization; sustained > 0.9 indicates SDS is the bottleneck
- Validate throughput against sizing calculations using `component_received_event_bytes_total{component_kind:source}`

---

## Sources

### Datadog Official Documentation

- [Best Practices for Scaling Observability Pipelines](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/)
- [Buffering and Backpressure](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/buffering_and_backpressure/)
- [Pipeline Usage Metrics](https://docs.datadoghq.com/observability_pipelines/monitoring_and_troubleshooting/pipeline_usage_metrics/)
- [Network Traffic Configuration](https://docs.datadoghq.com/observability_pipelines/configuration/network_traffic)
- [VM Deployment Architecture](https://www.datadoghq.com/architecture/op-vm-deployment/)
- [Kubernetes Deployment Architecture](https://www.datadoghq.com/architecture/observability-pipelines-kubernetes-deployment/)
- [OPW Helm Chart](https://github.com/DataDog/helm-charts/tree/main/charts/observability-pipelines-worker)
- [OPW Upgrade Guide](https://docs.datadoghq.com/observability_pipelines/guide/upgrade_worker/)

### Autoscaling

- [Datadog Pod Autoscaler](https://www.datadoghq.com/architecture/kubernetes-workload-autoscaling-with-datadog/)
- [KEDA Datadog Scaler](https://keda.sh/docs/2.16/scalers/datadog/)

### Benchmark Methodology

- **OPW version:** 2.20.4
- **Platform:** AWS EKS (us-west-2), Kubernetes
- **Instance type:** c7a.2xlarge (AMD EPYC Genoa, 8 vCPU, 16 GB)
- **Pod configuration:** StatefulSet, `requests: {cpu: 1, memory: 2Gi}`, no CPU limit
- **Test duration:** 15-minute steady-state windows per configuration
- **Workload:** eight event types, weighted average ~2,127 bytes/event
- **Validation:** zero errors, zero unintentional discards, zero CPU throttling confirmed for all configurations
