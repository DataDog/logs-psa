# ABB .NET logging XML

Example application that logs structured logs (JSON) using NLog - takes a large
XML object and extracts certain fields to be added to the log, rather than
logging the entire XML object.

__Internal Only__: Customer has XML data > 10mb, which cannot be submitted
as a single message to Datadog, message gets truncated. Additionally they want
to tie the log(s) to traces.

# Prerequisites

- .Net installed (https://dotnet.microsoft.com/en-us/download/dotnet/8.0)

# Running

- `dotnet run` - will produce json output to console and `mylog.log`

# Logs in Datadog

Configure your agent to read from whatever directory you've checked this repo
out into and tail the file `mylog.log`

It will look something like:
![img](screenshot-of-log-in-dd.png)
