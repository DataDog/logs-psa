# Containized Java Multi-line logging POC

Proof of concept to show Datadog's multi-line logging capability, reproducting
a customer environment. A simple java application that throws an exception run
from k8s, with containerized Datadog agent configured via helm.

## Prerequestites

### To build and run locally

- Java 11
- Maven

## Building

Run `mvn clean install`

## Running locally

Run `java -jar target/multiline-poc.jar`
