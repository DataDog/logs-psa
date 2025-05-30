#!/bin/bash

# Output log file
LOG_FILE="/var/log/fakelogs/fakelog.log"
# Number of log lines
NUM_LINES=100

# Arrays of sample data
methods=("GET" "POST" "HEAD")
paths=("/" "/index.html" "/login" "/images/logo.png" "/products" "/api/data" "/contact")
queries=("id=123" "user=admin" "ref=google" "-" "-" "-" "-")
user_agents=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
  "curl/7.68.0"
  "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X)"
)
statuses=(200 301 403 404 500)
ports=(80 443)

# Function to generate random IP
random_ip() {
  echo "$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256)).$((RANDOM%256))"
}

# Function to generate a log line
generate_log_line() {
  local date=$(date -u +"%Y-%m-%d")
  local time=$(date -u +"%H:%M:%S")
  local s_ip="192.168.1.1"
  local method=${methods[$RANDOM % ${#methods[@]}]}
  local path=${paths[$RANDOM % ${#paths[@]}]}
  local query=${queries[$RANDOM % ${#queries[@]}]}
  local port=${ports[$RANDOM % ${#ports[@]}]}
  local username="-"
  local c_ip=$(random_ip)
  local agent="${user_agents[$RANDOM % ${#user_agents[@]}]}"
  local status=${statuses[$RANDOM % ${#statuses[@]}]}
  local substatus=0
  local win32status=0
  local time_taken=$((RANDOM % 300))

  echo "$date $time $s_ip $method $path $query $port $username $c_ip \"$agent\" $status $substatus $win32status $time_taken"
}

for ((i=0; i<NUM_LINES; i++)); do
  generate_log_line >> "$LOG_FILE"
  sleep 0.1
done

echo "Generated $NUM_LINES fake IIS logs written to $LOG_FILE"
