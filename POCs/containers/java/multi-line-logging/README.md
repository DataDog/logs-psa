# Containized Java Multi-line logging POC

Proof of concept to show Datadog's multi-line logging capability, reproducting
a customer environment. A simple java application that throws an exception run
from k8s, with containerized Datadog agent configured via helm.

## Specfic Requirements

To mimic customer environment, we must use:

- Logback
- K8s
- Helm

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

Run `mvn clean install`

## Running locally

- `podman machine init --cpus 2 --memory 2048 --disk-size 20`
- `podman machine start`
- `podman system connection default podman-machine-default-root`
- `minikube start --driver=podman --container-runtime=cri-o`
