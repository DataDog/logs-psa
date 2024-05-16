# Rehydrate Old Logs [Proof of Concept]

## TODO (Kelner)

- [ ] Write up requirements for logs being sent for rehydration
- [ ] Write up cost considerations of doing it (double charged)
- [ ] Consider removing the lambda requirement, and lean on customers to find their own way to push logs to an S3 archive
- [ ] Watch <https://drive.google.com/file/d/1kExUCiYFRmSmuXydCWs7Qi29i-xHHy8c/view> to see if there's details to be gleaned.
- [ ] Go through steps of setup, capture the steps, make sure it works and there are no gaps

## Disclaimer

These projects are not a part of Datadog's subscription services and are provided for example purposes only. They are NOT guaranteed to be bug free and are not production quality. If you choose to use to adapt them for use in a production environment, you do so at your own risk.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [Overview](#overview)
  - [Is this an official Datadog Solution?](#is-this-an-official-datadog-solution)
  - [Log Retention Considerations](#log-retention-considerations)
- [Lambda Python Code](#lambda-python-code)
  - [lambda.py: Noteworthy](#lambdapy-noteworthy)
  - [Highlevel Lambda Setup & Flow Overview](#highlevel-lambda-setup--flow-overview)
    - [Setup](#setup)
    - [Continual running process until all historical logs have been ingested](#continual-running-process-until-all-historical-logs-have-been-ingested)
    - [Flowchat](#flowchat)
  - [Configuration > AWS > S3 Buckets](#configuration--aws--s3-buckets)
  - [Configuration > AWS > Lambda Function / S3 Trigger](#configuration--aws--lambda-function--s3-trigger)
  - [Datadog](#datadog)
    - [Log Archives](#log-archives)
      - [Config Overview in UI](#config-overview-in-ui)
      - [Archive Config](#archive-config)
      - [Rehydrate Config](#rehydrate-config)
    - [Pipelines](#pipelines)
  - [Misc. findings](#misc-findings)
    - [Log Archives naming](#log-archives-naming)
- [Manual script to rehydrate: dd-rehydrate-past.py](#manual-script-to-rehydrate-dd-rehydrate-pastpy)
  - [Brief](#brief)
  - [Logic flow](#logic-flow)
  - [Basic Usage](#basic-usage)
  - [Available Options](#available-options)
  - [Advanced Usage](#advanced-usage)
    - [Filtered by day](#filtered-by-day)
    - [Filtered by day & hour](#filtered-by-day--hour)
    - [Filtered using RegEx](#filtered-using-regex)
    - [Debug Output](#debug-output)
  - [Examples](#examples)
    - [Example 1](#example-1)
    - [Example 2](#example-2)
  - [Sample Processed Log Event](#sample-processed-log-event)
  - [Extra Tooling](#extra-tooling)
    - [Dummy Log Event Generator](#dummy-log-event-generator)
    - [Usage](#usage)
    - [Example Message](#example-message)
    - [Credentials](#credentials)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Overview

## Is this an official Datadog Solution?

No. It is admittedly a “hack“ of our own solution. The principle behind it is to trick Datadog into thinking it is rehydrating archives it previously created, while actually rehydrating logs which

The idea is to kickstart a prospect or customer into building their own solution to import historical logs from their former system into Datadog, hence the Proof-Of-Concept / non-official-solution disclaimers.

## Log Retention Considerations

Under the scenes, rehydrating effectively creates a new index which obeys the customer’s contractual log retention for their given DD org.

Should you require a log retention increase (say 6 months / 180 days for instance), this should occur before rehydration as the resulting index can only retain rehydrated logs for as long as the contractual retention period at the time of rehydration.

# Lambda Python Code
## Two Methods

Below are two methods in which you can restore logs to the Datadog platform. A brief description of the requirements, commonalities, and details of each is in the following two headings. Below this section you'll find top level headings for each.

### Pre-requisites for each

- You must write a script to pull your historical logs from some third-party location, such as Splunk, Elastic, Sumo, or blob storage such as S3.
- You must format those logs in JSON
- You must copy the original timestamp (usually `date` or `timestamp`) field to a new field on the log: `original_timestamp`
- You must replace the `date`/`timestamp` field with the current timestamp
- Then either write your logs to a DD compliant S3/GCP/Azure archive, or submit them to the Datadog API to be written to a bucket on your behalf via DD Archives
  - For writing logs to a DD compliant archive see the section [DD Compliant Logs Archive](#dd-compliant-archive) under the `Manual Script` section.

_There is more setup for the Lambda Function solution, it is detailed in the sections below_

### Manual Method

### Lambda Method

[Lambda Function details](#lambda-function)

In short your script submits logs to the DD API, is then written to an S3 bucket via DD Archives, then you rehydrate these logs into the DD platform under their original timestamp for querying.

**NOTE**: This method does have flaws. While it makes it easier to get logs into a Datadog compliant blob store, it also incurs some negatives, see the details section for more info.

1. Double charged for logs in Datadog: Once for API Submission, Once for rehydration using original timestamp.
2. You have logs in Datadog which may be confusing to users searching and troubleshooting. This method does not provide any tagging strategy or other mechanisms to help you differentiate between the two.
  a. However, you can use a strategy of exclusion filters to prevent them from being indexed but will still go to the archive. Discussed in more detail in [Lambda Method details](#lambda-method) below.
3. Focuses only on an AWS solution.
4. Requires additional infrastructure setup.


## lambda.py: Noteworthy

`target_bucket` and `original_timestamp` here are hard-coded in the script, please update these with a bucket you've created to have logs written to, and if using another attribute than `original_timestamp` on the incoming log, please update the variable with the correct value.

## Highlevel Lambda Setup & Flow Overview

### Setup

- User creates two buckets in their AWS account `source_bucket` and `target_bucket`
  - Bucket names can be whatever you like, see the `Configuration > AWS > S3 Buckets` section for details
- User creates Datadog log archives for `source_bucket` and `target_bucket`
  - See the `Log Archives` section below for details
- User writes a script to pull/scrape their historical logs from a given source, formats them as structured JSON (if not already JSON), copies the timestamp on the log into the field `original_timestamp`, then overwrites the standard `timestamp`/`date` field with the current timestamp, then submits the logs to the Datadog API
  - User should not run this script UNTIL the lambda and Datadog archives are setup first
- User installs `lambda.py` in their AWS account and sets up an S3 trigger for writes to `source_bucket`

### Continual running process until all historical logs have been ingested

- User runs their script to scrape/pull logs and submit to Datadog API
- Dataodg Archives writes logs submitted to Datadog API to `source_bucket`
- Custom Lambda gets triggered (invoked) for each log written by Datadog in `source_bucket`
- Custom Lambda parses `source_bucket` for log events archives matching `.*/archive_.*.json.gz`
- Custom Lambda parses log archives looking for `JSON` log events
- Custom Lambda processes log events by updating `date` with `original_timestamp`
- Custom Lambda writes processed & sorted log events to hourly archives in `target_bucket`
- User uses Datadog Archives to rehydrate log archives from `target_bucket` now with accurate timestamp

### Flowchat

![flowchart](images/lambda-flow.png)

## Configuration > AWS > S3 Buckets

Create two buckets

| bucket name   | description                                                               |
|---------------|---------------------------------------------------------------------------|
| d1c7d0a8      | _"source_bucket" - the bucket that Datadog will archive ingested logs to_ |
| 7c5fa03b      | _"target_bucket" - the bucket that Datadog will read archived logs from_  |

While it is possible to use the same bucket, **it is better practice to use distinct buckets** for a number of reasons:

- AWS cautions against it, when setting up bucket triggers:

> I acknowledge that using the same S3 bucket for both input and output is not recommended and that this configuration can cause recursive invocations, increased Lambda usage, and increased costs.

- Using distinct source / destination buckets guarantees that the bucket containing the **archives created by Datadog remains "pristine"**.
- Leaving their contents untouched / unmodified **ensures they can be used as the "source of truth"**.
- It also **provides more flexibility** later on in the process :
  - Should the S3-triggered Lambda post-processing fail for some reason, it remains possible to entirely wipe the target bucket and start over and re-process all events from the source bucket.

## Configuration > AWS > Lambda Function / S3 Trigger

Create an S3 trigger for your bucket with the `All object create events` for your "Event Types".

![add-trigger](images/lambda-trigger.png)
![event-types](images/event-types.png)

## Datadog

### Log Archives

<https://docs.datadoghq.com/logs/log_configuration/archives/?tab=awss3>

| config | archival                   | rehydration                   |
|--------|----------------------------|-------------------------------|
| filter | `*`                        |   `-*`                        |
| bucket | d1c7d0a8 (`source_bucket`) |   7c5fa03b (`target_bucket`)  |

#### Config Overview in UI

![flowchart](images/dd-logs-config-archives-0.png)

#### Archive Config

![dd-logs-config-archives-1-archival](images/dd-logs-config-archives-1-archival.png)

#### Rehydrate Config

![dd-logs-config-archives-2-rehydration](images/dd-logs-config-archives-2-rehydration.png)

### Pipelines

If you have many pipelines set for ingestion in Datadog, **a good practice would be to somehow distinguish Live Logs from Historical Logs**.

This is **especially important if you are using the date_mapper filter**.

This is because the lambda that will post-process logs will require specific attributes to exist in the JSON events to determine whether or not a specific log event should be processed.

## Misc. findings

### Log Archives naming

Datadog is actually able to rehydrate archives using a static / generic archive name such as `archive.json.gz`, providing:

- The S3 path to the archive does reflect the log's timestamp ( _/dt=YYYYMMDD/hour=HH/archive.json.gz_ )
- The `date` attribute does match the S3 path

## Extra Tooling

### Dummy Log Event Generator

Ship dummy log event using DD API

Depends on :

- `curl`
- `gdate` from `coreutils` brew package
- `diceware` `python3-pip` package

### Usage

`bash dd-ship-dummy-log.sh`

### Example Message

```json
 {
     "ddsource": "elasticsearch",
     "ddtags": "env:int,service:checkout,provider:gcp,region:eu-west-1,operation:read,id:47640a2c",
     "hostname": "emu-joylessly",
     "duration": "4.4431",
     "@timestamp": "2020-07-14T09:08:25.771Z",
     "original_timestamp": "2020-01-15T09:08:25.000Z",
     "message": "Lumpiness Freeness Result",
     "env":"int",
     "service":"checkout",
     "provider":"gcp",
     "region":"eu-west-1",
     "operation":"read",
     "id":"47640a2c"
 }
 ```

### Credentials

```bash
cat .env

 DD_CLIENT_API_KEY=01****************************7e
 DD_CLIENT_APP_KEY=aa************************************cf
```
