# Read from a Database and send to Observability Pipelines using a bash script

This directory contains instructions and reproduction on how to read from a MySQL database and send to Observability Pipelines.

This code is simplified and for example purposes only and not represenatative of production quality. Modify it to suite your needs.

Script runs for 60 seconds for easy cron job installation that runs every minute, but could be modified to run shorter or longer to pull more records.

Script currently set to pull 100 records LIMIT, but can easily be adjusted for more records for high volume situations.

# Setup

- A MySQL Server
- A host to run script
- A host running Observability Pipelines w/ HTTP Server source

> [!NOTE]
> For testing purposes these can all be the same host

# Bash Requirements

- `mysql` CLI tool installed
- `curl` installed
- Permissions to write a file locally to store last event counter
  - This avoids resending the same DB entry as a log multiple times

# Bash Script

See [read-db-send-op.sh](./read-db-send-op.sh).

# Testing setup & results

- MacOS X 15.4.1
- MySQL Server Running on localhost
- Observability Pipelines running via Docker Container on localhost port 9997

A simple OP Pipeline utilizing HTTP Server source:

![op-pipe.png]

A seed script for our database: [seed-mysql-db.sh](./seed-mysql-db.sh) - seeds 3000 DB entries

Results from running [read-db-send-op.sh](./read-db-send-op.sh):

![results.png]
