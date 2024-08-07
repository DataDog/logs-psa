# .NET logging XML Example

Example application that logs structured logs (JSON) using NLog.

In scenario #1 it takes an XML object and extracts certain fields to be added
to the log, rather than logging the entire XML object.

In scenario #2 is chunks an XML file (object) into 1MB log events (the DD
API Logs Ingest limit) and submits them to Datadog.

# Prerequisites

- .Net installed locally (https://dotnet.microsoft.com/en-us/download/dotnet/8.0)

# Running

- `dotnet run` - will produce json output to console and `mylog.log`

# Logs in Datadog

## Scenario #1
Configure your agent to read from whatever directory you've checked this repo
out into and tail the file `mylog.log`

It will look something like:
![img](screenshot-of-log-in-dd.png)

## Scenario #2
Configure your agent to read from whatever directory you've checked this repo
out into and tail the file `mylog.log`

It will look something like:
![img](screenshot-of-log-in-dd.png)
