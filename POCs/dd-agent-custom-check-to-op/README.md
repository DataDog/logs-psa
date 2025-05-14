# Datadog Agent Custom Check to OP

Collect output from arbitrary bash script via DD Agent Custom Check and submit it as a log to be sent to observability pipelines.

## Install the Agent

Install page: https://app.datadoghq.com/fleet/install-agent/latest?platform=overview

```bash
DD_API_KEY=abc...123 \
DD_SITE="datadoghq.com" \
bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_agent7.sh)"
```

## Configure the agent to collect logs

Configuration could be done via your configuration management tool of choice, for the sake of brevity in testing showcasing how to do so manually.

Config options: https://github.com/DataDog/datadog-agent/blob/main/pkg/config/config_template.yaml

- Uncomment `logs_enabled` [link](https://github.com/DataDog/datadog-agent/blob/main/pkg/config/config_template.yaml#L941-L949) and set it to `true`

```yaml
##################################
## Log collection Configuration ##
##################################

## @param logs_enabled - boolean - optional - default: false
## @env DD_LOGS_ENABLED - boolean - optional - default: false
## Enable Datadog Agent log collection by setting logs_enabled to true.
#
logs_enabled: true
```

## Configure the agent to listen for logs on a TCP port

This will be used to send logs from our custom check. Instead of writing to a file and tailing the file, which is a viable alternative.

- `sudo mkdir /etc/datadog-agent/conf.d/custom_logs.d/`
- `sudo vi /etc/datadog-agent/conf.d/custom_logs.d/conf.yaml`

    ```yaml
    logs:
        - type: tcp
            port: 10518
            service: "<APP_NAME>"
            source: "<CUSTOM_SOURCE>"
    ```

- Where `service` and `source` can be any values you like
  - `source` is used by Datadog SaaS pipelines to apply out-of-the-box log pipelines, you can write your own custom pipeline to parse logs as well

Restart the agent service: `sudo systemctl restart datadog-agent`

## Test sending logs over TCP

`curl telnet://localhost:10518/ -m 2 <<< '{"message":"test log"}'`

![tcp test log](./images/tcp-test-log.png)

