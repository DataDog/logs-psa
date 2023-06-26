# Containized Java Multi-line logging POC

Proof of concept to show Datadog's multi-line logging capability, reproducting
a customer environment. A simple java application that throws an exception run
from k8s, with containerized Datadog agent configured via helm.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [Directory Structure](#directory-structure)
  - [multiline-poc](#multiline-poc)
  - [multiline-poc-json](#multiline-poc-json)
- [Specfic Requirements](#specfic-requirements)
- [Notes](#notes)
  - [Logback Config](#logback-config)
  - [Helm Values vs Pod Annotations](#helm-values-vs-pod-annotations)
- [Datadog docs for reference](#datadog-docs-for-reference)
- [Prerequestites](#prerequestites)
- [Setup test environment](#setup-test-environment)
- [Build & Push](#build--push)
- [Running locally](#running-locally)
- [Triggering logs](#triggering-logs)
- [Cleanup](#cleanup)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Directory Structure

There are two java projects here-in, each with their own helm charts, one using json logs and the
other does not. All other commands in this readme aside from directory names, work exactly the
same across both.

This readme focuses on the non-json approach as it was the customer's choice, however Datadog
recommends logging in JSON when possible.

### multiline-poc

Uses a basic and assumed Logback configuration that does NOT log to JSON.

### multiline-poc-json

Uses the `LogstashEncoder` so that a customer can see what it would look like should
they choose to use it in their project.

## Specfic Requirements

To mimic customer environment, we must use:

- Logback
- NOT using the `LogstashEncoder` recommended by Datadog
- K8s
- Helm

## Notes

### Logback Config

At the time of writing we didn't have details on the exact Logback configuration being used
by the customer, but we assumed they were following Datadog's recommendation and using
`net.logstash.logback.encoder.LogstashEncoder`
(<https://docs.datadoghq.com/logs/log_collection/java/?tab=logback#configure-your-logger>).

After some investigation using the `LogstashEncoder` we noted that they were most likely
not using it, as the attributes and formatting of the logs were quite dissimilar from
what they provided us.

Internal examples from this POC application: <https://a.cl.ly/lluX2gbW> & <https://a.cl.ly/JruegyBN>.
Further on with <https://docs.datadoghq.com/logs/error_tracking/>: <https://a.cl.ly/jkuRDON6>

### Helm Values vs Pod Annotations

Both are possible, and there are other methods as well, however helm charts and pod annotations are
easier to maintain and far more human friendly and readable.

Rather than setting `--set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS` via
helm, and setting patterns across all containers, assume that customer would be ok using pod annotations in their
charts, as described here: <https://docs.datadoghq.com/containers/kubernetes/log/?tab=kubernetes#configuration>
    a. `--set agents.containers.agent.envDict.DD_LOGS_CONFIG_AUTO_MULTI_LINE_EXTRA_PATTERNS='(..@timestamp|\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})'` will work here, but it will apply to all containers, and we want to set the `source` to
    `java` anyway in the pod annotation, to ensure it is going through the correct pipeline (as described here:
    <https://docs.datadoghq.com/logs/log_collection/java/?tab=logback#configure-the-datadog-agent> or here:
    <https://docs.datadoghq.com/agent/logs/advanced_log_collection/?tab=configurationfile>)
    b. TODO: Find out if the customer would be ok with this approach

## Datadog docs for reference

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
        datadog/datadog
- Deploy our java app
        helm upgrade multiline-poc ./k8s/multiline-poc/ --install \
        -f ./k8s/multiline-poc/values.yaml
- `minikube tunnel`
- Open <http://127.0.0.1:8080/>

## Triggering logs

- Open <http://127.0.0.1:8080/exception>

## Cleanup

- `minikube stop`
- `minikube delete`
