# Containized Java Multi-line logging POC

Proof of concept to show Datadog's multi-line logging capability, reproducting
a customer environment. A simple java application that throws an exception run
from k8s, with containerized Datadog agent configured via helm.

## Specfic Requirements

To mimic customer environment, we must use:

- Logback
- K8s
- Helm

## Assumptions

1. At the time of writing we didn't have details on the exact Logback configuration being used
by the customer, but we assumed they were following Datadog's recommendation and using
`net.logstash.logback.encoder.LogstashEncoder`
(<https://docs.datadoghq.com/logs/log_collection/java/?tab=logback#configure-your-logger>).
    a. TODO: Find out exact configuration and implement here

2. Rather than setting `--set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS` via
helm, and setting patterns across all containers, assume that customer would be ok using pod annotations in their
charts, as described here: <https://docs.datadoghq.com/containers/kubernetes/log/?tab=kubernetes#configuration>
    a. TODO: Find out if the customer would be ok with this approach; easier to maintain and
    far more human friendly and readable
    b. `--set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS='(..@timestamp|\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})'` will work here, but again it will apply to all containers, and we want to set the `source` to
    `java` anyway in the pod annotation, to ensure it is going through the correct pipeline (as described here:
    <https://docs.datadoghq.com/logs/log_collection/java/?tab=logback#configure-the-datadog-agent> or here:
    <https://docs.datadoghq.com/agent/logs/advanced_log_collection/?tab=configurationfile>)

## Datadog docs

- <https://docs.datadoghq.com/agent/logs/advanced_log_collection/?tab=configurationfile#multi-line-aggregation>
- <https://docs.datadoghq.com/logs/log_collection/java/?tab=logback>
- <https://www.datadoghq.com/blog/multiline-logging-guide/>

## Prerequestites

- Java 11
- Maven
- Helm
- k8s cluster
  - _the author is using minikube_

## Setup test environment

- `minikube start --driver=docker --memory 2048 --cpus 2 --nodes 2`
- `minikube addons enable metrics-server`

## Build & Push

- Run `mvn clean install -f ./multiline-poc/pom.xml`
- `docker build . -t multiline-poc:latest`
- `minikube image load multiline-poc:latest`

## Running locally

- `helm repo add datadog https://helm.datadoghq.com`
- `helm repo update`
- Customer's preferred method of deploy/configure (rather than yaml):
        helm upgrade \
        -n default \
        -i datadog-agent \
        --set datadog.apiKey=<REPLACE_WITH_YOUR_ENV_VAR_OR_STRING> \
        --set datadog.kubelet.tlsVerify=false \
        --set datadog.logs.enabled=true \
        --set datadog.logs.containerCollectAll=true \
        --set datadog.logs.autoMultiLineDetection=true \
        --set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS='(..@timestamp|\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})' \
        datadog/datadog
- `
