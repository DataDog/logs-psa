#!/bin/bash

# Output log file
LOG_FILE="/var/log/fakelogs/fakelog.log"

# Sample user agents and paths
user_agents=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
  "curl/7.68.0"
  "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X)"
)

urls=(
  "/"
  "/login"
  "/dashboard"
  "/api/data"
  "/logout"
  "/favicon.ico"
)

status_codes=(200 301 403 404 500)

# Function to generate a random IP
random_ip() {
  echo "$((RANDOM % 256)).$((RANDOM % 256)).$((RANDOM % 256)).$((RANDOM % 256))"
}

# Function to generate a log line
generate_log_line() {
  ip=$(random_ip)
  datetime=$(date '+%d/%b/%Y:%H:%M:%S %z')
  method="GET"
  url=${urls[$RANDOM % ${#urls[@]}]}
  status=${status_codes[$RANDOM % ${#status_codes[@]}]}
  size=$((RANDOM % 9000 + 200))
  referrer="-"
  agent=${user_agents[$RANDOM % ${#user_agents[@]}]}

  echo "$ip - - [$datetime] \"$method $url HTTP/1.1\" $status $size \"$referrer\" \"$agent\""
}

# Number of log lines to generate
NUM_LINES=100

# Write logs to file
for ((i=0; i<NUM_LINES; i++)); do
  generate_log_line >> "$LOG_FILE"
  sleep 0.1
done

echo "Generated $NUM_LINES fake Nginx logs in $LOG_FILE"
