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

# Loop to print 300 log messages
for i in {1..300}; do
    # Any CLI utility could be called here and the output captured and echoed out
  timestamp=$(date +"%Y-%m-%d %H:%M:%S:%N")  # Get current timestamp with nanoseconds
  random_log=${logs[$RANDOM % ${#logs[@]}]}
  # Print $i to guarantee unique log entries
  echo "[$1] [$i] [$timestamp] $random_log"
done
