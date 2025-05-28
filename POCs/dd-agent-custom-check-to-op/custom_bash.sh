#!/bin/bash

# Array of sample log messages
logs=(
  "User logged in"
  "File uploaded"
  "Transaction completed"
  "Error occurred in module X"
  "User logged out"
  "Permission denied"
  "Email sent"
  "Disk space low"
  "Service restarted"
  "New user registered"
)

# Loop to print 3 log messages
for i in {1..3}; do
    # Any CLI utility could be called here and the output captured and echoed out
  timestamp=$(date +"%Y-%m-%d %H:%M:%S:%N")  # Get current timestamp with nanoseconds
  random_log=${logs[$RANDOM % ${#logs[@]}]}
  # Print $i to guarantee unique log entries
  echo "[$1] [$i] [$timestamp] $random_log"
  sleep 0.01  # Optional: pause for 0.1 second between logs
done
