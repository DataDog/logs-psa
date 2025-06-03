# Token Based Routing to Multiple OPW on the same host

Example of how to set up token based routing using an AWS ELB to OP Workers running on the same  host with Splunk Universal Forwarders sending traffic to the ELB.

## Design

![arch](./images/design.png)

## Observability Pipelines

- Create 3 OP Pipelines (one for each token): https://app.datadoghq.com/observability-pipelines
- For simplicity sake use the log volume control template for each
- Select "Splunk HEC" as the source
- Select "Datadog Logs" as the destination
- Delete all processors except "Edit Fields"
- Set "Edit Fields" processor to "Add Field"
- Set "Filter Query" to `*`
- Set "Field to add" to `op_token`
- Set "Value to add" to `1111`, `2222`, and `3333` to differentiate between the 3 pipelines in the Datadog log explorer
- Click on "Next Install"
- Select your target platform (for this POC: Ubuntu)
- Input listener address of: `0.0.0.0:8282`
- Select an API key with RC enabled

Keep these pages open and move to the next section.

## Observability Pipelines Host

- Spin up a single Ubuntu instance
- Copy and run the "Install the Observability Pipelines Worker" command from the Datadog UI from the first pipeline (`1111`):

    ```bash
    DD_API_KEY=aeb5...a756 DD_OP_PIPELINE_ID=89f6f736-3cd7-11f0-a00b-da7ad0900002 DD_SITE=datadoghq.com DD_OP_SOURCE_SPLUNK_HEC_ADDRESS='0.0.0.0:8282' bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_op_worker2.sh)"
    ```

- Verify the host is reporting to the control plane:

    ![op-detected](./images/op-detected.png)

- Click "Deploy" - the `Status` column will updated to `Deployed` once the configuration has been pulled by the OP Worker
- Follow the instructions for running multiple OPW per host: https://docs.datadoghq.com/observability_pipelines/set_up_pipelines/run_multiple_pipelines_on_a_host/
    - Repeat this twice for a total of 3 OPWs
    - When modifying the environment file, e.g. `/etc/default/<filename>` be sure to:
        - Replace `DD_OP_PIPELINE_ID` with the correct pipeline id for each unique pipeline (3 total)
        - Replace `DD_OP_SOURCE_SPLUNK_HEC_ADDRESS` with a new port (e.g. `8383` and `8484`) as two processes cannot listen on the same port on the same interface (OS limitation); now if you have multiple network interfaces you could replace `0.0.0.0` with the appropriate interface, for this POC we have a single network interface.
    - As you start each worker at the end of the documentation, return to the Datadog UI and click "Deploy" to get the pipeline configuration loaded on the worker
- Now 3 OP Workers are running on the same host running 3 distinct pipelines:

    ![3-op-workers-same-host](./images/3-op-workers.png)

- Next [enable the OPW API](https://docs.datadoghq.com/observability_pipelines/troubleshooting/#enable-the-observability-pipelines-worker-api) for our next section to add a `/health` endpoint for our load balancer
- `vi /etc/default/<filename>` the first installed workers is at `/etc/default/observability-pipelines-worker` and the other two are names that were chosen when following the multiple pipelines pre host step
    - Add `DD_OP_API_ENABLED=true`
    - Add `DD_OP_API_ADDRESS=0.0.0.0:8686`
- Restart the workers:
    - `sudo systemctl daemon-reload && sudo systemctl restart observability-pipelines-worker`
    - `sudo systemctl restart <service-name>` for the other two

## ELB Setup

### Security Group

- Use a common SG for the OP instances and LB
    - Allow traffic on the ports `8282`, `8383`, `8484`, and `8686` from the SG
- Allow port `8080` from your sources to the ALB

### Target Groups

- Create 3 target groups, one for each port (`8282` `8383` `8484`)
- Choose `Instances` as the "Target Type"
- For "Protocol" choose `HTTP` and one of the three ports OP is listening on
- Configure the health check for `HTTP` with a path of `/health` and under advanced options override the port to `8686`
- Under "Register Targets" select the OP instance

![target-groups](./images/target-groups.png)

### Load Balancer

- Create a new load balancer
- Select "Application Load Balancer" as the type
- For simplicity sake of this POC choose "Internet Facing" but your networking setup may dictate/support "Internal"
- Fill out the required fields for "Network Mapping"
- Choose the same Security Group as the OP instances where we opened rules earlier
- "Listeners and Routing" input port `8080` and select the first target group associated with `8282` - this will be our default route, but we'll add other rules for headers in the next steps
- Deploy the load balancer

### Listener Rules

- After the load balancer is available click on your listener and click "Add Rules"
- Add 3 rules
- For each add a condition
    - Select `HTTP Header`
    - Header name: `Authorization`
    - Header value: `Splunk <token>` where token is `Splunk 11111111-1111-1111-1111-111111111111`, `Splunk 22222222-2222-2222-2222-222222222222`, `Splunk 33333333-3333-3333-3333-333333333333`
    - ![condition](./images/rule-condition.png)
- For each forward to the appropriate target group (one for each port `8282`, `8383`, and `8484`)

Now we have three rules routing based on header tokens:
![rules](./images/rules.png)

## Manually testing sources

Token 1:

```bash
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 11111111-1111-1111-1111-111111111111" -d '{"event": "hello world", "host": "token-1"}'
{"text":"Success","code":0}
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 11111111-1111-1111-1111-111111111111" -d '{"event": "this came from token 1111...", "host": "token-1"}'
{"text":"Success","code":0}
```

Token 2:

```bash
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 22222222-2222-2222-2222-222222222222" -d '{"event": "hello world", "host": "token-2"}'
{"text":"Success","code":0}
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 22222222-2222-2222-2222-222222222222" -d '{"event": "this came from token 2222...", "host": "token-2"}'
{"text":"Success","code":0}
```

Token 3:

```bash
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 33333333-3333-3333-3333-333333333333" -d '{"event": "hello world", "host": "token-3"}'
{"text":"Success","code":0}
curl -k http://kelnerhax-multi-op-2081698429.us-west-2.elb.amazonaws.com:8080/services/collector/event -H "Authorization: Splunk 33333333-3333-3333-3333-333333333333" -d '{"event": "this came from token 3333...", "host": "token-3"}'
{"text":"Success","code":0}
```

This gives the following results:

![manual-results](./images/manual-results.png)

Here we can see that the appropriate `@OP_TOKEN` is being applied by OPW "Edit Fields" processor as they match the `host` we sent in our requests from (via event attribute), which means our requests are being routed appropriately by the ALB to the correct port mapping to the correct OPW process on the OP host.
