# SDS Logs + OP

Test for Singapore Airlines use case (SIA): <https://docs.google.com/presentation/d/1-Pycu8ZIAnddZ3WJ87Ol48juzDL_LuPTuZN5wSUy-jo/edit#slide=id.g1e4fba1a4d5_1_8>

**WORK IN PROGRESS** -- **INTERNAL REFERENCE ONLY**

## Agent and python script for logs

- Assumes debian VM of some kind
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

You can use a non-sensical query that returns zero logs (e.g. `source:idontexist`). You must add the path `/` unless you specified something different in your OP sink, if you specify nothing OP uses `/` by default, the two MUST match whatever you choose to do.

## Observability Pipelines

- Follow <https://docs.datadoghq.com/observability_pipelines/setup/datadog/?tab=aptbasedlinux>
  - `vector` mentioned for Agent yaml config, but latest is `observability_pipelines_worker`
  - Use `pipeline.yaml` for your config
- Follow <https://docs.datadoghq.com/observability_pipelines/setup/datadog/?tab=aptbasedlinux#connect-the-datadog-agent-to-the-observability-pipelines-worker>
  - Is isn't explicitly called out, but you need to restart the agent

## Rehydrate

<https://app.datadoghq.com/logs/pipelines/historical-views>

NOT WORKING ATM - see notes below

## Raw notes / troubleshooting

### July 19 2023 EOD PT

Raw notes from Slack msg I sent to Ari and Wei Chiang:

> Chris Kelner :heads-down:  6:25 PM
> got it configured with AWS, but same issue, none of the OP logs will rehydrate.
> Logs are there: <https://a.cl.ly/2Nup7yQr>
> Archives are setup: <https://a.cl.ly/Jrue86re>
> No logs other than the ones that match the filter on the DD Archive in the platform (not from OP)
> <https://a.cl.ly/7KuWkLKl>
> <https://a.cl.ly/KouE1rPW>
> But we expect to see these: <https://a.cl.ly/eDuE7Bq8>
> I did find this interesting...

```
gunzip ~/Downloads/archive_52e97e12-89ea-4b9b-9f20-d9b8b193f1aa.json.gz
gunzip: /Users/chris.kelner/Downloads/archive_52e97e12-89ea-4b9b-9f20-d9b8b193f1aa.json.gz: not in gzip format
```

> And if I rename and drop the .gz I can open it as .json... so something fishy there?! Maybe a clue?
> And what is inside is what we expect:

```
{"_id":"AYlwxygu2byqvCYQqjgACcYd","attributes":{"ddsource":"rsyslog","ddtags":"filename:syslog,opw_aggregator:kelnerhax,sender:observability_pipelines_worker","hostname":"kelnerhax.c.datadog-sandbox.internal","source_type":"datadog_agent"},"date":"2023-07-20T00:50:37.760Z","message":"Jul 20 00:35:06 kelnerhax sds-logs.py: {\"source\": \"python\", \"tags\": \"env:prod, version:5.1, kelner:hax\", \"hostname\": \"i-02a4fd78aa35b\", \"message\": \"transferring money to bank account: GB65EXBT46039777534172\", \"service\": \"charge-back\"}","service":""}
{"_id":"AYlwxygu2byqvCYQqjgACcYe","attributes":{"ddsource":"rsyslog","ddtags":"filename:syslog,opw_aggregator:kelnerhax,sender:observability_pipelines_worker","hostname":"kelnerhax.c.datadog-sandbox.internal","source_type":"datadog_agent"},"date":"2023-07-20T00:50:37.760Z","message":"Jul 20 00:35:06 kelnerhax sds-logs.py: {\"source\": \"python\", \"tags\": \"env:prod, version:5.1, kelner:hax\", \"hostname\": \"i-02a4fd78aa35b\", \"message\": \"querying credit score for SSN: 075-40-1078\", \"service\": \"charge-back\"}","service":""}
{"_id":"AYlwxygu2byqvCYQqjgACcYf","attributes":{"ddsource":"rsyslog","ddtags":"filename:syslog,opw_aggregator:kelnerhax,sender:observability_pipelines_worker","hostname":"kelnerhax.c.datadog-sandbox.internal","source_type":"datadog_agent"},"date":"2023-07-20T00:50:37.760Z","message":"Jul 20 00:35:06 kelnerhax sds-logs.py: {\"source\": \"python\", \"tags\": \"env:prod, version:5.1, kelner:hax\", \"hostname\": \"i-02a4fd78aa35b\", \"message\": \"transferring money to bank account: GB05CQBW88345662986437\", \"service\": \"charge-back\"}","service":""}
```

> @Ari thoughts when you have a chance? Maybe there is some config I am missing in vector that is screwing up the gzip?
