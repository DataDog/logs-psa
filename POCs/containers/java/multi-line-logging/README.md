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

## Datadog docs

- <https://docs.datadoghq.com/agent/logs/advanced_log_collection/?tab=configurationfile#multi-line-aggregation>
- <https://docs.datadoghq.com/logs/log_collection/java/?tab=logback>
- <https://www.datadoghq.com/blog/multiline-logging-guide/>

## Prerequestites

- Java 11
- Maven
- Helm
- k8s cluster
  - _the author is using podman + minikube w/ the CRI-O runtime_
    - podman
    - minikube

## Building

- `cd multiline-poc`
- Run `mvn clean install`
- `cd ..`
- `docker buildx build . -t multiline-poc:latest`

## Running locally

- `podman machine init --cpus 2 --memory 2048 --disk-size 20`
- `podman machine start`
- `podman system connection default podman-machine-default-root`
- `minikube start --driver=podman --container-runtime=cri-o`
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
- TBD
