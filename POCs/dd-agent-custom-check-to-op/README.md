# Datadog Agent Custom Check to OP

Collect output from arbitrary bash script via DD Agent Custom Check and submit it as a log to be sent to observability pipelines.

# Setup

## Install the Agent

- Install page: https://app.datadoghq.com/fleet/install-agent/latest?platform=overview
- Config options: https://github.com/DataDog/datadog-agent/blob/main/pkg/config/config_template.yaml

```
DD_API_KEY=abc...123 \
DD_SITE="datadoghq.com" \
DD_ENV=dev \
DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED=true \
DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL=localhost \
DD_LOGS_ENABLED=true \
bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_agent7.sh)"
```
