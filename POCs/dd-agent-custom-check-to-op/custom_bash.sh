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

# Any CLI utility could be called here and the output captured and echoed out
# Loop to print 3 log messages
for i in {1..3}; do
  timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  random_log=${logs[$RANDOM % ${#logs[@]}]}
  echo "[$timestamp] $random_log"
  sleep 1  # Optional: pause for 1 second between logs
done
