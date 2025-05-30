#!/bin/bash

# Output log file
LOG_FILE="/var/log/fakelogs/fakelog.log"
# Number of log lines to generate
NUM_LINES=100

# Arrays of log levels and messages
levels=("notice" "warning" "verbose")
components=("RDB" "AOF" "Server" "Client" "Cluster")
events=(
  "Background saving started by pid 12345"
  "DB saved on disk"
  "RDB: 0 MB of memory used by copy-on-write"
  "Accepted 127.0.0.1:6379"
  "Client closed connection"
  "Connected to master 192.168.1.1:6379"
  "Master replied to PING"
  "Synchronizing with master"
  "AOF rewrite started"
  "AOF rewrite finished successfully"
  "Cluster state changed: ok"
  "CONFIG SET maxclients 10000"
  "GET key -> value"
  "SET key value"
)

# Generate a Redis-style timestamp
timestamp() {
  date +"%d %b %Y %H:%M:%S.%3N"
}

# Generate a log line
generate_log_line() {
  ts=$(timestamp)
  level=${levels[$RANDOM % ${#levels[@]}]}
  component=${components[$RANDOM % ${#components[@]}]}
  message=${events[$RANDOM % ${#events[@]}]}

  echo "$ts [$level] $component: $message"
}

for ((i=0; i<NUM_LINES; i++)); do
  generate_log_line >> "$LOG_FILE"
  sleep 0.05  # Optional: simulate streaming
done

echo "Generated $NUM_LINES fake Redis logs written to $LOG_FILE"
