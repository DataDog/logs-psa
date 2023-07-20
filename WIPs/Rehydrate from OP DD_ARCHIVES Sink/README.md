# SDS Logs + OP

**WORK IN PROGRESS**

**FOR INTERNAL REFERENCE ONLY**

Assumes debian

## Agent and python script for logs

**FOR TESTING PURPOSES ONLY**

- install the agent: <https://app.datadoghq.com/account/settings/agent/latest?platform=debian>
- edit `/etc/datadog-agent/datadog.yaml`
  - set `logs_enabled: true`
- tail syslog
  - `sudo -S -u dd-agent mkdir /etc/datadog-agent/conf.d/kelnerhax.d/`
  - `sudo -S -u dd-agent vi /etc/datadog-agent/conf.d/kelnerhax.d/conf.yaml`
    - copy `conf.yaml` contents
- make syslog readable by agent: `sudo chmod 644 /var/log/syslog`
- restart agent: `sudo service datadog-agent restart`
- run `sudo pip3 install faker`

## Pipeline processor(s)

- create grok processor in a pipeline for rsyslog, copy contents of `grok-processor.regex`
- you'll likely need a few remappers (e.g. service) as well to handle rsyslog
  - at the time of writing no OOTB pipeline for rsyslog

## Setup SDS

- Go to <https://app.datadoghq.com/organization-settings/sensitive-data-scanner>
- Setup a group with a filter for `service:charge-back`
- Add all the OOTB CC scanners
- Add additiona SSN scanners:
  - `^(\d{3}-?\d{2}-?\d{4}|XXX-XX-XXXX)$`
  - `(?:\d{3}-?\d{2}-?\d{4})`

## Archive Bucket

Follow datadog docs for whichever flavor you are using: <<https://docs.datadoghq.com/logs/log_configuration/archives/?tab=awss3&site=us#configure-an-archive> (Note>: I started with GCP, but it didn't work)<https://docs.datadoghq.com/logs/log_configuration/archives/?tab=googlecloudstorage>)

Be sure to actually filter on some very low volume logs that exist, otherwise the archive will never become active and rehyrdration WILL NOT WORK. You must also add the path of `/` unless you specified something different in your OP sink, if you specify nothing OP seems to use `/` by default, the two MUST match whatever you choose to do. See these screenshots:

- <https://a.cl.ly/L1uv9pQd>
- <https://a.cl.ly/wbuLQWPR>

I have not tested setting it up and then chaging the filter after, but I believe it will get stuck in this same state after editing as it return to the _italizized_ text and hover text on edit.

## Observability Pipelines

- Follow <https://docs.datadoghq.com/observability_pipelines/setup/datadog/?tab=aptbasedlinux>
  - A few additional commands that might be useful:
    - `sudo touch /etc/default/observability-pipelines-worker`
    - `sudo chmod 766 /etc/default/observability-pipelines-worker`
    - copy contents (and modify as needed)
- Follow <https://docs.datadoghq.com/observability_pipelines/setup/datadog/?tab=aptbasedlinux#connect-the-datadog-agent-to-the-observability-pipelines-worker>

## Rehydrate

<https://app.datadoghq.com/logs/pipelines/historical-views>

You MAY have to use `*` and no be specific due to the way the fake Archive is setup within Datadog. I tried using `service:chargeback` which is not part of the platform archive filter and it didn't work.
