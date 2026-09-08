# Observability Pipelines Worker (OPW) - Sizing, Scaling, and Performance Guide

**Deployment target:** 10 TB/day total volume (steady state ~7 TB/day, peak ~14 TB/day, 2x peak-to-trough)

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
|   OTel, Splunk)  |   NLB    |  3-6 pods      |          |   Elasticsearch) |
+------------------+          +----------------+          +------------------+
                              3.5 vCPU / 7 GiB each
                              40 GiB disk buffer
```

**Key architecture decisions:**

- **L4 load balancer (NLB)** in front of OPW for push-based sources. L7 (ALB) adds unnecessary overhead. Client-side load balancing is explicitly not recommended (complexity, data loss risk). ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

- **Shared-nothing architecture** - no leader election, no coordination between workers. Each pod is independent. Horizontal scaling is trivial.

- **No single instance should process more than 33% of total volume** for HA during node failure. At 3 minReplicas, each pod handles 33% - at the HA boundary. At 4+ pods (during scaling), each pod handles 25% or less. ([Source](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/))

### Deployment Approaches

[Official docs reference](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#centralized-vs-decentralized-approach)

| Approach | Description | Best For |
|---|---|---|
| **Centralized** | Single OPW cluster | Low volume, simple topology |
| **Decentralized** (recommended) | OPW per region/cluster | High volume, multi-region |
| **Hybrid** | OPW per region, not per cluster | Large deployments (6 regions, 60 clusters -> 6 OPW deployments) |

At 10 TB/day, centralized is viable if all sources are in a single region. Move to decentralized when adding regions or when cross-region transit costs become significant.

---

## Sizing Methodology

### The "1 TB per vCPU per day" Planning Baseline

The conservative planning baseline is **1 TB/day per vCPU** (approximately 10 MiB/s per vCPU for ~512-byte unstructured log events). This number comes from the [official Datadog docs](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/) and assumes a pipeline with 12 processors performing typical log transforms.

**Always start with the 1 TB/vCPU/day formula.** This is conservative, and pipeline complexity can exceed the tiers tested. Oversize initially, monitor performance using self-reported OPW metrics, and optimize after observing the system.

**Throughput by event type:**

| Event Type | Typical Size | Per-vCPU Throughput |
|---|---|---|
| Unstructured logs | ~512 bytes | ~10 MiB/s |
| Structured logs | ~1.5 KB | ~25 MiB/s |

Source: [Scaling documentation](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/best_practices_for_scaling_observability_pipelines/#units-for-estimations)

### Sizing Formula

```
Required vCPU = (daily volume in TB) / (TB per vCPU per day for your tier)
Required pods = ceil(Required vCPU / vCPU per pod)
```

Add 25% headroom above the baseline. Always enable autoscaling. Set the HPA maximum to 2x the baseline to absorb daily fluctuations and spikes.

### Event Size Matters

The benchmarks in this guide used a heterogeneous workload averaging approximately 2,127 bytes per event. Throughput in bytes per second is relatively stable across event sizes, but throughput in events per second varies. If your events are smaller (under 512 bytes), expect higher events-per-second rates at similar bytes-per-second throughput. If your events are larger (over 4 KB), expect lower events-per-second rates.

### Impact of SDS (Sensitive Data Scanner)

SDS is the heaviest OPW processor. Rule count and scoping dramatically affect throughput.

**Key SDS optimizations (ranked by impact):**

1. **Field scoping** - Target SDS to only PII-containing fields/services rather than scanning all fields. Can more than double throughput for high rule-count pipelines (+149% at 40 rules).

2. **Disable unused rules** - Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules.

3. **Rule splitting** - Split >20 SDS rules across multiple SDS processors (e.g., 40 rules into 2x20). This breaks head-of-line (HOL) blocking in OPW's Tokio FIFO task queue, where a single large SDS processor starves other pipeline tasks. At 4 vCPU with 40 unsplit rules, actual CPU utilization caps at ~2.8 vCPU because ~1.2 vCPU idles waiting for SDS. Splitting into 2x20 recovers ~3.7 vCPU (+45% throughput). Start splitting at >20 rules per processor.

4. **Pre-filter** - Filter out logs before SDS. Place volume-reduction processors (filter, sample, throttle, quota, dedupe) before SDS.

5. **Horizontal scaling** - Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries since each pod has an independent Tokio runtime.

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

All results measured at ~1 vCPU on AWS EKS with c7a.2xlarge instances (AMD EPYC Genoa). Test workload: seven event types, weighted average ~2,127 bytes per event, sustained over 30-minute steady-state windows.

| Pipeline Tier | TB/day per vCPU | Events/s | MB/s | CPU (1 Pod) | Memory (RSS) |
|---|---|---|---|---|---|
| Basic Processing | 4.70 | 26,734 | 45.6 | 0.84 | 159 MB |
| Medium + SDS, targeted (10 rules) | 3.61 | 19,087 | 40.6 | 0.97 | 228 MB |
| Medium + SDS, blanket (10 rules) | 2.95 | 15,300 | 32.5 | 0.95 | 220 MB |
| Heavy + SDS, targeted (40 rules) | 1.97 | 10,635 | 22.6 | 0.99 | 234 MB |
| Heavy + SDS, blanket (40 rules) | 0.79 | 4,288 | 9.1 | 1.00 | 226 MB |

### The Cost of Blanket Scanning

Blanket scanning with 40 rules consumes 83% of the throughput available to a no-SDS pipeline. A pipeline that processes 10 TB/day at the Basic tier would need over 6x the compute to handle the same volume with 40-rule blanket SDS.

| Pipeline Configuration | TB/day per vCPU | vs Basic |
|---|---|---|
| Basic Processing (no SDS) | 4.70 | baseline |
| Medium + SDS, targeted (10 rules, 20% of events) | 3.61 | -23% |
| Medium + SDS, blanket (10 rules, all events) | 2.95 | -37% |
| Heavy + SDS, targeted (40 rules, 20% of events) | 1.97 | -58% |
| Heavy + SDS, blanket (40 rules, all events) | 0.79 | -83% |

---

## Deployment Sizing Table

These are **minimums** assuming **targeted SDS scanning** with **25% capacity headroom**. Weighted toward the conservative 1 vCPU per 1 TB/day baseline. Always enable autoscaling with max = 2x baseline.

A configuration such as **5 x 2 vCPU** means **five workers, each allocated 2 vCPUs**.

| Daily Volume | Basic Processing | Medium + SDS (targeted) | Heavy + SDS (targeted) |
|---|---|---|---|
| 5 TB/day | 3 x 1 vCPU | 5 x 1 vCPU | 4 x 2 vCPU |
| **10 TB/day** | **3 x 2 vCPU** | **5 x 2 vCPU** | **6 x 3 vCPU** |
| 50 TB/day | 10 x 3 vCPU | 17 x 3 vCPU | 30 x 3 vCPU |
| 100 TB/day | 20 x 3 vCPU | 34 x 3 vCPU | 60 x 3 vCPU |

**If your pipeline uses blanket SDS scanning,** multiply the Heavy + SDS pod count by approximately 2.5x.

### 10 TB/day Capacity Math

10 TB/day is the **total daily volume**. Log traffic is not uniform: most environments see a 2x peak-to-trough ratio between business-hours peaks and off-hours steady state. Size the fleet for the **peak rate**, not the daily average.

Using the conservative 1 TB/vCPU/day baseline:

```
Daily volume: 10 TB/day
  Steady state rate (0.7x): 7 TB/day = 81 MB/s
  Peak rate (2x steady):    14 TB/day = 162 MB/s

  The fleet runs at steady state ~57% of the day and peak ~43% of the day.
  (0.57 x 7) + (0.43 x 14) = 4.0 + 6.0 = 10 TB/day total.

minReplicas: size for HA and steady state (7 TB/day)
  = 7 vCPU at 100% utilization
  = 10 vCPU at 70% target utilization
  = 3 pods at 3.5 vCPU/pod (minimum HA recommendation)
  3 pods x 3.5 vCPU = 10.5 vCPU -> 67% utilization at steady state
  At 100%, 3 pods = 10.5 vCPU, covers steady state + handles most peaks.
  If one pod becomes unavailable, the two remaining pods can absorb traffic
  until the replacement is ready.

maxReplicas: size for peak (14 TB/day)
  = 14 vCPU at 100% utilization
  = 20 vCPU at 70% target utilization
  = 6 pods at 3.5 vCPU/pod
  6 pods x 3.5 vCPU = 21 vCPU capacity

Node pool requirements (2 pods per 8-vCPU node, 2 x 3.5 = 7.0 vCPU + 1.0 for OS/kubelet):
  At 6 pods on c7i.2xlarge (8 vCPU, 2 pods/node): 3 nodes
```

---

## Resource Configuration

### CPU

- **3.5 vCPU per pod** for efficient binpacking on 8-vCPU nodes (2 x 3.5 = 7.0 vCPU, leaving 1.0 for kubelet/DaemonSets/OS). At `cpu: "4"`, Kubernetes cannot fit 2 pods on an 8-vCPU node after accounting for kubelet reservations and DaemonSets.
- SDS-heavy pipelines show diminishing returns above 3-4 vCPU due to HOL blocking. At 4 vCPU with 40 unsplit SDS rules, actual CPU utilization caps at ~2.8 vCPU.
- **No CPU limit** - CPU limits cause CFS throttling, which creates artificial backpressure in a CPU-bound workload. The official OPW Helm chart intentionally omits CPU limits.
- Use **non-burstable instances** (AWS c7i/c7g, GCP c2/c4a, Azure Fsv2). Burstable instances (t-family, e2, B-series) throttle under sustained OPW load.

### Memory

- **2 GiB per vCPU** minimum (docs baseline)
- **Set limits.memory equal to requests.memory** - This creates Guaranteed QoS class for the memory dimension, prevents OOMKill during burst buffering and backpressure events, avoids memory overcommit, and protects against kubelet eviction under node memory pressure.
- Memory increases with number of destinations (each destination has in-memory batching/buffering)
- **Avoid unbounded cardinality in Sample/Quota processors** (grouping on `message` or other high-cardinality fields causes monotonic memory growth)
- `MALLOC_CONF="thp:never,dirty_decay_ms:1000,muzzy_decay_ms:1000"` - forces jemalloc to return pages faster after bursts (not a leak; allocator behavior)

### Why Not Sub-1 vCPU Per Pod?

- OPW is CPU-bound. At sub-1 vCPU, each pod processes proportionally less data, so you need many more pods. Scheduling overhead and PVC count scale linearly.
- At 1 vCPU, HOL blocking cannot occur (only one thread). This makes 1 vCPU the smallest pod size where per-core SDS throughput is maximally efficient.
- The memory overhead per pod (jemalloc, destination buffers, runtime) is roughly fixed regardless of CPU allocation. At sub-1 vCPU, the memory-to-CPU ratio becomes inefficient.

If your use case requires lower resource consumption per pod, use 1 vCPU pods with more aggressive horizontal scaling rather than fractional CPU.

### Disk

- Disk specs rarely matter for OPW itself (~500 MB install)
- Disk throughput matters for **disk buffer drain** scenarios: gp3 baseline is ~125 MB/s per node, shared across pods on that node
- Size PVC 10% larger than pipeline disk buffer `max_size` (OPW validates at startup). **If a disk buffer volume reaches 100% capacity (ENOSPC), partial writes can corrupt the buffer.** OPW will loop attempting to drain, emitting `Events dropped` with `unprocessable_events` errors. Always provision the PVC at least 10% larger than the pipeline's configured `max_size`. Monitor `pipelines.data_dir_available_bytes` and alert when free space drops below 15% of capacity.
- Structural ceiling per worker: 128 MB files x 65,536 max files = ~8 TB per disk buffer

---

## Autoscaling

### HPA (Built-in)

The `values.yaml` configures HPA with:

| Parameter | Value | Rationale |
|---|---|---|
| minReplicas | 3 | 10.5 vCPU; handles 7 TB/day steady state at ~67% util; HA minimum |
| maxReplicas | 6 | 21 vCPU; handles 14 TB/day peak at ~67% util |
| targetCPU | 70% | 30% burst headroom per pod |
| scaleUp stabilization | 0s | Small fleet: immediate reaction, cost of false positive is one pod |
| scaleUp policy | +100%/min (Percent) | Can reach maxReplicas in one step at this fleet size |
| scaleDown stabilization | 900s (15 min) | Prevent oscillation |
| scaleDown policy | -10%/min (Min) | Slow, conservative |

**Small-fleet scaleUp rationale:** At 3-6 pods, the cost of one unnecessary scale-up is one additional pod (minimal). The benefit of immediate reaction is avoiding backpressure and 503s during traffic spikes. Percent 100 at 3 pods = +3 pods, reaching maxReplicas (6) in a single step. This is appropriate for small fleets where the blast radius of overshoot is low.

**When to switch to the large-fleet pattern:** If your fleet grows beyond ~20 pods, switch to the 100TB/300TB pattern: `stabilizationWindowSeconds: 60`, `Percent: 50`, and add a `Pods` floor (e.g., value: 20). At larger scale, unnecessary scale events are expensive (node provisioning, PVC creation, NLB target registration) and the stabilization window filters transient metric noise.

**HPA Scale-Up Timeline (steady state to peak):**

```
T+0 min:  3 pods  (10.5 vCPU)  - Peak traffic ramps. CPU rises above 70%.
                                  3 pods at 100% = 10.5 vCPU, covers 10.5 TB/day.
T+1 min:  6 pods  (21 vCPU)    - HPA doubles fleet, capped at max. Full headroom restored.
                                  Peak demand (14 TB/day = 14 vCPU) is 67% of capacity.
```

Peak demand: 14 vCPU at 100% utilization. Fleet exceeds demand at T+1 min.

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

**Why `source_buffer_utilization_mean` is #1:** It is the only metric that reliably RISES during all forms of backpressure (SDS saturation, destination outage, processing bottleneck). CPU and `utilization` both DROP during stall conditions.

**IMPORTANT:** `source_buffer_utilization_mean` reports raw event counts, not a 0-1 ratio. Maximum value = vCPU x 1,000 (e.g., 3,500 for a 3.5-vCPU pod). Set KEDA thresholds as absolute values. For a 3.5-vCPU pod, 50% of capacity = 1,750.

### KEDA ScaledObject Manifest

Deploy this alongside OPW. Set `autoscaling.enabled: false` in the Helm values when using KEDA.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: datadog-keda-secret
  namespace: observability-pipelines
type: Opaque
data:
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
    kind: StatefulSet
    name: opw-observability-pipelines-worker
  minReplicaCount: 3
  maxReplicaCount: 6
  cooldownPeriod: 300
  pollingInterval: 15
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          # Small fleet: 0s stabilization, Percent 100.
          # Switch to 60s/50% when fleet exceeds ~20 pods.
          stabilizationWindowSeconds: 0
          policies:
            - type: Percent
              value: 100
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
    # PRIMARY: backpressure (buffer utilization)
    # source_buffer_utilization_mean reports raw event counts, NOT 0-1.
    # Max value = vCPU x 1000. For 3.5-vCPU pods: 50% of 3500 = 1750.
    # Adjust queryValue when changing pod vCPU size.
    - type: datadog
      metadata:
        query: "avg:pipelines.source_buffer_utilization_mean{pipeline_id:<PIPELINE_ID>}"
        queryValue: "1750"
        queryAggregator: "avg"
        age: "120"
        metricUnavailableValue: "0"
      authenticationRef:
        name: datadog-auth
    # SECONDARY: CPU saturation
    # 3.5 vCPU = 3500m, 60% = 2100m = 2,100,000,000 nanocores
    - type: datadog
      metadata:
        query: "avg:kubernetes.cpu.usage{kube_stateful_set:opw-observability-pipelines-worker}"
        queryValue: "2100000000"
        queryAggregator: "avg"
        age: "120"
        metricUnavailableValue: "0"
      authenticationRef:
        name: datadog-auth
    # EMERGENCY: active data loss
    - type: datadog
      metadata:
        query: "sum:pipelines.component_discarded_events_total{pipeline_id:<PIPELINE_ID>,intentional:false}.as_rate()"
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
  |  Disk:   min ~256 MB, max 5 TB (Worker 2.20.0+; 500 GB on earlier versions),
  |          128 MB files, fsync every 500ms
  |  Fills -> depends on when_full policy (block or drop_newest)
  v
[Destination]
```

Source: [Buffering and Backpressure docs](https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/buffering_and_backpressure/)

### Backpressure Signals

`source_buffer_utilization_mean` reports **raw event counts** (max = vCPU x 1,000), not a 0-1 ratio. The thresholds below are expressed as percentages of capacity.

| Signal | Log / Metric | Severity | Meaning |
|---|---|---|---|
| Source send latency rising | `pipelines.source_send_batch_latency_seconds` | Early | Downstream processing slower than ingest |
| Source buffer filling | `pipelines.source_buffer_utilization_mean` > 50% of capacity | Warning | Halfway to capacity |
| "Source send cancelled" | OPW log at WARN level | High | Source producing faster than downstream consumes |
| Source buffer near full | `pipelines.source_buffer_utilization_mean` > 90% of capacity | Critical | About to drop events |
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
  PVC = 41 * 1.10 = ~45 GiB -> round to 40 GiB (sufficient for 10 TB/day)
```

At 10 TB/day, a 36 GiB buffer provides ~20 minutes of runway per pod. The `values.yaml` uses 40 GiB PVC (36 GiB max_size + filesystem overhead).

**Disk buffer limits:** Minimum 256 MB, maximum 5 TB (Worker 2.20.0+; 500 GB on earlier versions). On-disk format uses 128 MB data files with fsync every 500 ms. Data written within the last 500 ms is at risk on an unexpected crash.

**`when_full` policies:**

| Policy | Behavior | Use When |
|---|---|---|
| `block` (default) | Backpressure propagates upstream. No data loss. | Sources have retry/buffer capability (DD Agent, OTel with persistent queue) |
| `drop_newest` | New events silently dropped. No backpressure. | Dual-shipped sources where original is preserved elsewhere (e.g., Splunk HF also sends to Splunk indexers) |

**Multi-destination fanout caveat:** If backpressure propagates from ANY destination, ALL destinations are blocked. Use `drop_newest` on non-critical destination buffers to isolate failures.

### Graceful Shutdown

When OPW receives `SIGTERM`, it executes a graceful shutdown in this order:

1. The health/readiness API is marked not-serving. Kubernetes stops routing new traffic to the pod.
2. All HTTP sources stop accepting new TCP connections immediately. In-flight requests on existing connections are completed.
3. No new events enter the pipeline after in-flight requests finish.
4. Transforms drain naturally as their input channels close.
5. Sinks flush remaining events from their buffers to the destination.
6. Once all components finish, OPW exits.

The drain time formula only accounts for events already in the pipeline at the moment of `SIGTERM`, not continuous live ingest. OPW closes the listener before draining begins.

```
terminationGracePeriodSeconds = DD_OP_GRACEFUL_SHUTDOWN_LIMIT_SECS + 10
```

- The Helm chart derives `DD_OP_GRACEFUL_SHUTDOWN_LIMIT_SECS = terminationGracePeriodSeconds - 10`. Supported since OPW 2.19.0.
- A second `SIGTERM` during graceful shutdown triggers immediate exit with no further draining.
- Default tGPS: 70s (chart default) - too low for meaningful disk buffers
- Observed drain rate at 2 vCPU: approximately 54 MB/s. A 36 GiB buffer at 54 MB/s drains in ~11 minutes.
- Production reference for 10 TB/day: 310s (300s for OPW drain + 10s margin)

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

Daily traffic follows a diurnal pattern: ~57% of the day at steady state (7 TB/day rate), ~43% at peak (14 TB/day rate), averaging to 10 TB/day total. The peak transition is handled by three layers:

```
Layer 1: MINIMUM REPLICAS (HA baseline)
  3 pods at ~67% steady-state utilization
  Each pod has ~43% burst headroom (67% -> 100%)
  3 pods at 100% = 10.5 vCPU, covers 10.5 TB/day
  Brief sender buffering may occur if peak exceeds 10.5 TB/day rate

Layer 2: AGGRESSIVE HPA/KEDA scaleUp
  +100% pods per minute (small fleet pattern)
  Reaches peak capacity in ~1 minute
  Brief sender buffering during initial ramp

Layer 3: UPSTREAM SENDER BUFFERING
  DD Agent: retries indefinitely as long as log remains on disk
  OTel Collector: persistent queue + retry + memory_limiter
  Splunk UF: retry with tcpout
  ...
  Senders hold data locally when OPW returns HTTP 503
```

### Timeline Analysis: Steady State to Peak

```
T+0:00  Peak traffic ramps. 162 MB/s hitting 3 pods (capacity: 105 MB/s at 100%)
        Each pod: 54 MB/s demand vs 35 MB/s capacity
        Pods burst from 67% toward 100%. Excess causes brief 503s.
        Upstream senders begin buffering locally.
        HPA detects high CPU.

T+1:00  HPA scales to 6 pods (no stabilization window for small fleets).
        Fleet: 6 pods (capacity: 210 MB/s at 100%, 147 MB/s at 70%)
        Capacity EXCEEDS peak demand. Senders begin draining.

T+2-3:  Sender buffers fully drained. System stable at ~67% utilization.

        [Peak period: ~10 hours at 14 TB/day rate]

T+end:  Peak subsides. scaleDown begins after 900s stabilization.
        scaleDown removes ~10%/min. Fleet: 6 -> 5 -> 4 -> 3
        Back to 3 pods within ~15 min.
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
      storage: file_storage
extensions:
  file_storage:
    directory: /var/lib/otelcol/queue
```

The DD Agent retries indefinitely as long as the log remains on disk.

### Burst Protection: Throttle/Quota Processor

For environments with unpredictable spikes from specific services, use the **Throttle (Quota) processor** in the OPW pipeline:

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
| 1 | **Field/service scoping** | +149% throughput | Target SDS to only PII-containing fields/services. If only 20% of events contain PII, scope SDS to those services. |
| 2 | **Disable unused rules** | Varies | Most deployments use 10-30 of 270+ available rules. Each rule has CPU cost even if it never matches. Use `pipelines.sds_rule_matched_total` to identify zero-match rules. |
| 3 | **Rule splitting** | +45% throughput | Split >20 SDS rules across multiple SDS processors (e.g., 40 rules -> 2x20). Breaks HOL blocking in Tokio's FIFO task queue. |
| 4 | **Horizontal scaling** | Linear | Add pods rather than vCPUs. HOL blocking cannot occur across pod boundaries. |
| 5 | **Pre-filter** | Varies | Filter out logs before SDS. Place volume-reduction processors (filter, sample, throttle, quota, dedupe) before SDS. |

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

**Why splitting works:** OPW processes events concurrently across multiple threads. A single SDS processor with many rules creates long per-event processing times that cause head-of-line blocking in OPW's internal task queue. Events are dispatched as concurrent tasks, but the queue requires tasks to complete in order. Splitting reduces per-event scan time per processor, shortening the queue head's hold time and allowing more threads to stay active.

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
- Split rules across multiple SDS processors.
- Replace CPU-based HPA with KEDA/DPA scaling on `source_buffer_utilization_mean`.

---

## Kubernetes Deployment

[Kubernetes Deployment Architecture](https://www.datadoghq.com/architecture/observability-pipelines-kubernetes-deployment/)

### Instance Selection

Use compute-optimized, non-burstable instances with at least 8 vCPU per node:

| Cloud | Recommended Instance Types |
|---|---|
| AWS | c7i.2xlarge, c7a.2xlarge, c7g.2xlarge (Graviton) |
| Azure | F8s v2, F16s v2, D8ps_v6 (Cobalt) |
| GCP | c2-standard-8, c2-standard-16, c4a-standard-8 (Axion) |
| On-prem / bare metal | At least 8 vCPUs and 16 GiB of memory (2 GiB per vCPU) |

Avoid burstable instances (AWS t-family, Azure B-series, GCP e2). OPW under sustained load will exhaust CPU credits and throttle.

### Pod Scheduling

- **Pod anti-affinity:** Soft preference for one OPW pod per node. One node failure = one pod lost, not all.
- **Topology spread:** Pods spread across AZs with `maxSkew: 1`. Remove if single-AZ cluster.
  - **Cost note:** Multi-AZ topology spread means cross-zone traffic. AWS charges ~$0.01/GB for cross-AZ within region. GCP does not charge. Azure varies. At 10 TB/day, this is approximately $2K/month on AWS if all traffic crosses zones.
- **Pod disruption budget:** `minAvailable: 2` - at 3 pods, only 1 can be disrupted at once.
- **Pod management policy:** `Parallel` for fast HPA scale-up. `OrderedReady` is too slow for traffic spikes.
  - **Azure/AKS caveat:** `podManagementPolicy: Parallel` can cause Multi-Attach errors during rolling updates with ReadWriteOnce PVCs (new pod scheduled before old terminates on a different node = volume conflict). Mitigate by scaling down before helm upgrade, using `maxUnavailable` to limit churn, or deleting the StatefulSet with `--cascade=orphan` before upgrading.
- **Update strategy:** `RollingUpdate` with `maxUnavailable: 1`.

### Additional Recommendations

- **Pin to a specific image tag.** Pin to a version (e.g., `2.20.4`) and upgrade deliberately. Review the [changelog](https://docs.datadoghq.com/observability_pipelines/guide/upgrade_worker/).
- **Dedicated node pool.** Isolate OPW from application workloads.
- **jemalloc tuning:** `MALLOC_CONF="thp:never,dirty_decay_ms:1000,muzzy_decay_ms:1000"`
- **High availability:** Always deploy at least 3 OPW pods. In HA testing, killing one pod in a three-replica deployment resulted in zero events dropped, with surviving pods absorbing full load within 36 seconds.

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

---

## VM Deployment

[VM Deployment Architecture](https://www.datadoghq.com/architecture/op-vm-deployment/)

### Instance Sizing

Use compute-optimized instances. OPW is CPU-bound, and memory consumption is modest.

| Cloud | Minimum | Recommended |
|---|---|---|
| AWS | c7i.xlarge (4 vCPU, 8 GB) | c7i.2xlarge (8 vCPU, 16 GB) |
| Azure | F4s v2 (4 vCPU, 8 GB) | F8s v2 (8 vCPU, 16 GB) |
| GCP | c2-standard-4 (4 vCPU, 16 GB) | c2-standard-8 (8 vCPU, 32 GB) |
| On-prem / bare metal | 4 vCPU, 8 GB (2 GiB per vCPU) | 8 vCPU, 16 GB (2 GiB per vCPU) |

### Instance Group and Autoscaling

Deploy OPW in a managed instance group (AWS ASG, GCP MIG, Azure VMSS) behind a network load balancer (L4). Do not use an application load balancer (L7).

- **Scale up at 70% average CPU.** For SDS-heavy pipelines, lower to 50-60%.
- **Minimum 3 instances** for high availability.
- **Cap individual instances at 50% of total pipeline volume.**
- **Enable the OP API** for health checks: `DD_OP_API_ENABLED=true` and `DD_OP_API_ADDRESS=0.0.0.0:8686`.

### Load Balancer Configuration

- **Protocol**: TCP (L4). Do not use an application load balancer (L7) - OPW traffic is high-throughput and L7 inspection adds unnecessary overhead.

- **Health check**: HTTP GET on port 8686. Requires `DD_OP_API_ENABLED=true` and `DD_OP_API_ADDRESS=0.0.0.0:8686`.

- **Distribution**: No major cloud provider's NLB supports round-robin - all use hash-based distribution. Cloud NLBs (AWS NLB, GCP Network LB, Azure Standard LB) use a flow hash algorithm based on the connection's 5-tuple (source IP/port, destination IP/port, protocol). Each TCP connection is pinned to a single target for its lifetime. New connections are distributed across healthy targets. With many log sources (e.g., a DaemonSet with 50+ nodes), the hash distributes connections evenly across OPW targets. For on-premises L4 load balancers (HAProxy, NGINX), use round-robin or least-connections.

- **Connection recycling**: OPW automatically recycles HTTP/1.x connections every ~5 minutes (built-in default, 300s with 10% jitter). The server sends `Connection: close` on the next response after the deadline, forcing the client to reconnect with a new source port and flow hash. This is not configurable through the OP pipeline UI.

- **TCP idle timeout**: Ensure this exceeds OPW's connection recycling maximum (330s) to prevent the LB from closing connections before OPW can gracefully cycle them.
  - **AWS NLB:** defaults to 350 seconds (configurable 60-6,000s). 350s is appropriate. Sends TCP RST on expiry.
  - **GCP Internal NLB:** defaults to 600s (configurable 60-600s). 600s is appropriate. No RST on expiry - stale connections silently reroute. Client keepalives are critical.
  - **GCP External NLB:** defaults to 60s (not configurable). Set client keepalive to 20-25s.
  - **Azure Standard LB:** 4 min default (configurable 4-100 min). Increase to at least 6 min so the timeout exceeds OPW's connection recycling (330s max). Enable TCP Reset (`--enable-tcp-reset true`) - the default silently drops connections with no notification to either side.
  - **Rule of thumb**: client keepalive interval < LB timeout / 2.

- **Low number of clients**: If you have fewer than ~10 log sources (e.g., syslog aggregators, Splunk Heavy Forwarders), or traffic passes through a NAT gateway that collapses source IPs, the flow hash may produce uneven distribution. In this case: configure sources to use multiple concurrent connections, and right-size OPW pods so each pod can absorb the largest single-client connection.

- **Cross-zone load balancing**: Enable cross-zone. Even target distribution across OPW pods is critical - a single overloaded pod can trigger saturation and buffer backpressure. Uneven pod-per-AZ distribution is common during scaling events, node failures, and PVC zone affinity.
  - **AWS NLB:** Cross-zone is disabled by default. Enable it. AWS charges ~$0.01/GB for cross-zone data transfer. At 10 TB/day, this is approximately $2K/month.
  - **GCP:** Cross-zone is the default behavior and free within a region.
  - **Azure:** Zone-redundant distribution is the default and free within a VNet.

- **Client-side load balancing**: DNS round-robin or application-level load balancing is not recommended. Use a network load balancer for health-aware distribution.

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

Datadog provides a built-in dashboard: **Observability Pipelines Overview**. It covers throughput, component health, buffers, errors, CPU/memory, and SDS matches. No configuration required.

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
| Warning | `data_dir_available_bytes` | < 15% of capacity | Disk buffer filling (ENOSPC risk) |
| Warning | `http_client_errors_total` | > threshold | Destination returning errors |
| Warning | `source_lag_time_seconds` p95 | > SLO threshold | Events arriving stale |

### Key Metrics Quick Reference

**Throughput:**
- `pipelines.component_received_bytes_total{component_kind:source}.as_rate()` - ingest bytes/s (primary sizing validation)
- `pipelines.component_sent_event_bytes_total{component_kind:sink}.as_rate()` - egress bytes/s
- `pipelines.component_received_events_total{component_kind:source}.as_rate()` - ingest events/s

**Backpressure (most reliable to least):**
- `pipelines.source_buffer_utilization_mean` - EWMA source buffer fill. Best single metric. Reports raw event counts (max = vCPU x 1,000), not 0-1. Use a formula monitor (`utilization_mean / max_size_events`) for pod-size-independent thresholds.
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
- **Enable cross-zone load balancing.** Even target distribution across OPW pods is critical. Disable only if cost is prohibitive and you enforce strict even pod distribution with hard topology spread constraints.
- **TCP idle timeout:** Ensure LB idle timeout exceeds 330s (OPW's connection recycling maximum). See the Load Balancer Configuration section for CSP-specific values.

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

**Pipeline design:**
- Filter, reduce, throttle, apply quotas, and sample early: place before SDS and other expensive processors
- Add processors incrementally, not in large batches; observe each addition's impact

**Deployment:**
- Always deploy at least 3 replicas for high availability
- Do not set CPU limits on OPW pods
- Use compute-optimized, non-burstable instance types
- Use L4 network load balancers, not L7 application load balancers
- For Kubernetes: enable PodDisruptionBudget, pod anti-affinity, and topology spread constraints
- Allowlist required Datadog domains for outbound HTTPS (port 443) if network restricts egress

**Autoscaling:**
- Use CPU-based HPA at 70% target for standard pipelines (no SDS or <20 rules)
- Use KEDA or DPA with `source_buffer_utilization_mean` for SDS-heavy pipelines (20+ rules)
- For small fleets (<20 pods): 0s stabilization, Percent 100 scaleUp
- For large fleets (20+ pods): 60s stabilization, Percent 50 scaleUp with Pods floor
- Configure conservative scale-down (15-min stabilization, 10%/min)
- Set max replicas to 2x baseline for burst absorption

**Buffering:**
- Use disk buffers when data durability during destination outages matters
- Set `when_full: drop_newest` on non-critical destination buffers to prevent multi-destination blocking
- Set `terminationGracePeriodSeconds` to cover your maximum buffer drain time
- Provision PVCs at least 10% larger than pipeline disk buffer max_size to prevent ENOSPC corruption

**Monitoring:**
- Alert on `component_discarded_events_total{intentional:false}` (critical: any non-zero)
- Alert on `source_buffer_utilization_mean` (warning at 70% of capacity, critical at 90%); this metric reports raw event counts (max = vCPU x 1,000), not 0-1. Use a formula monitor (`utilization_mean / max_size_events`) for pod-size-independent thresholds.
- Monitor SDS utilization; sustained > 0.9 indicates SDS is the bottleneck
- Validate throughput against sizing calculations using `component_received_bytes_total{component_kind:source}`

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

- **Platform:** AWS EKS (us-west-2), Kubernetes
- **Instance type:** c7a.2xlarge (AMD EPYC Genoa, 8 vCPU, 16 GB)
- **Pod configuration:** StatefulSet, `requests: {cpu: 1, memory: 2Gi}`, no CPU limit
- **Test duration:** 30-minute steady-state windows per configuration
- **Workload:** seven event types, weighted average ~2,127 bytes/event
- **Validation:** zero errors, zero unintentional discards, zero CPU throttling confirmed for all configurations

---

## Suggested Edits: Cross-Comparison of 100TB/300TB READMEs vs Google Doc

The following discrepancies were identified between the existing 100TB/300TB reference READMEs and the Google Doc (sizing guide). These should be reconciled across all references.

### 1. HA minimum: 2 vs 3 replicas

- **100TB/300TB READMEs:** State "Always deploy at least three OPW pods" and use minReplicas of 40/100 (well above 3). The HA test description mentions "three-replica deployment."
- **Google Doc:** Updated to "Always deploy at least three OPW pods or VMs." The sizing table uses 3 as the minimum. Draft guide originally said "at least two."
- **Recommendation:** All sources now agree on 3. Correct.

### 2. Test duration: 15-minute vs 30-minute windows

- **100TB/300TB READMEs:** State "15-minute steady-state windows."
- **Google Doc:** Updated to "30-minute steady-state windows."
- **Recommendation:** Update the 100TB/300TB READMEs to say "30-minute" to match the Google Doc. The Google Doc is the authoritative published version.

### 3. Event type count: "eight" vs "seven"

- **100TB/300TB READMEs:** State "eight event types."
- **Google Doc:** States "seven event types" and the workload table lists 7 types (loadgenerator was removed).
- **Recommendation:** Update the 100TB/300TB READMEs to say "seven" and remove `loadgenerator` from workload descriptions.

### 4. Primary ingest metric name

- **100TB/300TB READMEs:** Use `pipelines.component_received_event_bytes_total{component_kind:source}` as the primary ingest metric.
- **Google Doc:** Uses `pipelines.component_received_bytes_total{component_kind:source}` (no "event_" in the name).
- **Recommendation:** Verify which is the current metric name in the latest OPW version and align all references.

### 5. Memory limits guidance

- **100TB/300TB READMEs:** Set `limits.memory = requests.memory` (Guaranteed QoS on memory dimension).
- **Google Doc:** Shows `limits.memory = 2x requests.memory` in the generic K8s section, but the 10TB reference config sets `limits.memory = requests.memory`.
- **Recommendation:** The reference configs should all use limits = requests (Guaranteed QoS). The Google Doc's generic section should note this as the recommended pattern, with 2x as an alternative for environments that want burst headroom.

### 6. Disk buffer maximum size

- **100TB/300TB READMEs:** State "maximum 500 GB."
- **Google Doc:** States "maximum 5 TB (Worker 2.20.0 and later; 500 GB on earlier versions)."
- **Recommendation:** Update the 100TB/300TB READMEs to include the 5 TB limit for Worker 2.20.0+.

### 7. Drain rate observations

- **100TB/300TB READMEs:** Do not cite specific drain rate numbers.
- **Google Doc:** Cites "approximately 54 MB/s" at 2 vCPU. The draft guide cites "8-10 MiB/s" at 1 vCPU.
- **Recommendation:** Both numbers may be correct at their respective vCPU allocations. Include the 54 MB/s figure in the 100TB/300TB READMEs since they use 3.5 vCPU pods.

### 8. SIGTERM/drain behavior detail

- **100TB/300TB READMEs:** Minimal description of shutdown behavior.
- **Google Doc:** Detailed 6-step SIGTERM shutdown sequence, clarifying that drain only accounts for events already in the pipeline (not continuous ingest).
- **Recommendation:** Add the detailed shutdown sequence to the 100TB/300TB READMEs.

### 9. Load balancer section

- **100TB READMEs:** Original LB section has errors (round-robin, 60s keepalive, cross-zone disabled by default).
- **Google Doc:** Updated with corrected LB guidance (flow hash, CSP-specific idle timeouts, cross-zone enabled).
- **Recommendation:** Update the 100TB/300TB README "Load Balancing" sections and values.yaml service annotations to match the corrected guidance. The 100TB values.yaml still has `cross-zone-load-balancing-enabled: "false"` which contradicts the corrected recommendation.

### 10. ENOSPC disk buffer corruption caveat

- **100TB/300TB READMEs:** Not mentioned.
- **Google Doc:** Includes the ENOSPC corruption warning: "If a disk buffer volume reaches 100% capacity (ENOSPC), partial writes can corrupt the buffer."
- **Recommendation:** Add this caveat to the 100TB/300TB READMEs in the Disk Buffer Configuration section.

### 11. Target CPU: 60% vs 70%

- **100TB/300TB READMEs + values.yaml:** Use 60% target CPU.
- **Google Doc:** Recommends 70% as the default, with 60% for large production fleets (100+ TB/day).
- **Recommendation:** This is intentional differentiation. The 100TB/300TB configs are large-fleet configs where 60% is appropriate. The 10TB config uses 70% for cost efficiency at small scale. Both are consistent with the Google Doc's guidance. No change needed.
