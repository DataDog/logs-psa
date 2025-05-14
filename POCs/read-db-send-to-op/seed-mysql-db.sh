#!/bin/bash

# Database connection details
DB_HOST="localhost"
DB_USER="root"
DB_PASS="password"

# Create database and table
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "
CREATE DATABASE IF NOT EXISTS logs;
USE logs;
CREATE TABLE IF NOT EXISTS log_entries (
    id INT AUTO_INCREMENT PRIMARY KEY,
    log TEXT NOT NULL,
    transaction_id VARCHAR(255),
    event_id VARCHAR(255)
);
"

# Generate and insert 3000 random entries
for i in $(seq 1 3000); do
    log="Random log message $i"
    transaction_id="TX$((100000 + RANDOM % 900000))"
    event_id="$(printf "$i")"

    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" logs -e "
    INSERT INTO log_entries (log, transaction_id, event_id)
    VALUES ('$log', '$transaction_id', '$event_id');
    "
done

echo "Database 'logs' and table 'log_entries' seeded successfully."
