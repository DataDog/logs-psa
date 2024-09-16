# Observability Pipelines on EKS with public load balancer

## Setup OP Worker(s) in EKS

- In Datadog navigate to https://app.datadoghq.com/observability-pipelines
- Select a template that fits your use case
- Fill in the source, destinations, and processors you want
    - For simplicity sake you can remove all processors for now and OP will act as a "pass through"
        - You can add processors later
- Choose “Next: Install” at top right of pipeline builder
- Choose “Kubernetes” and “Amazon EKS”
- For your source address: this is the local socket that OPW will be listening on to receive logs from your collector/forwarders (e.g. Datadog Agent, Rsyslog, Splunk Forwarders, etc)
    - In the supplied values file below this will also be exposed via a Load Balancer
- Note: You'll see the instructions "Download the Helm chart `values.yaml` file" - this **does not** contain a load balancer, this repo [contains a `values.yaml` that configured an exposed LB for you](./values.yaml)
    - You can find all available values in the helm chart here: https://github.com/DataDog/helm-charts/blob/main/charts/observability-pipelines-worker/values.yaml
- Run the helm install command:

    ```
    helm upgrade --install opw \
	-f values.yaml \
	--set datadog.apiKey=XXXXXXXXXXXXXXXXXXXXXX \
	--set datadog.pipelineId=df657176-745e-11ef-9ff0-da7ad0900002 \
	--set env[0].name=DD_OP_SOURCE_SPLUNK_HEC_ADDRESS,env[0].value='0.0.0.0:8888' \
	--set service.ports[0].name=dd-op-source-splunk-hec-address-port,service.ports[0].protocol=TCP,service.ports[0].port=8888,service.ports[0].targetPort=8888 \
	datadog/observability-pipelines-worker
    ```

- Get your Load Balancer with: `kubectl get svc` and you should get output like:

    ```

    ```

- While your load balancer address may show here, it does take some time to provision, so you'll need to check its status via `kubectl describe svc opw-observability-pipelines-worker` or via AWS console https://us-west-2.console.aws.amazon.com/ec2/home?region=us-west-2#LoadBalancers:v=3;$case=tags:false%5C,client:false;$regex=tags:false%5C,client:false (search for your LB and check its status is `active`)

## Fake logs

Supplemental for testing purposes is [`fake-logs.yaml`](./fake-logs.yaml) which will generate some fake VPC logs and
send them to the OPW endpoint that is exposed to generate some traffic.

You can also test this via curl from your local machine:

```
curl -k http://a003a1a88ff8b42fdb05e8bb1d8e79d8-b0147bca32a05c83.elb.us-west-2.amazonaws.com:8888/services/collector/event -d '{ "event": "this is my log message"}'
```
