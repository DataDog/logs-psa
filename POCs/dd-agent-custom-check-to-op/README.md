# Datadog Agent Custom Check to OP

Collect output from arbitrary bash script via DD Agent Custom Check and submit it as a log to be sent to observability pipelines.

## Install the Agent

Install page: https://app.datadoghq.com/fleet/install-agent/latest?platform=overview

```bash
DD_API_KEY=abc...123 \
DD_SITE="datadoghq.com" \
bash -c "$(curl -L https://install.datadoghq.com/scripts/install_script_agent7.sh)"
```
