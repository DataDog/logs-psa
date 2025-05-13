#!/bin/bash

# Database connection details
# DB_HOST="localhost"
# DB_USER="your_user"
# DB_PASS="your_password"

# Create database and table SQL
SQL_COMMANDS=$(cat <<EOF
CREATE DATABASE IF NOT EXISTS logs;

USE logs;

CREATE TABLE IF NOT EXISTS log_entries (
    id INT AUTO_INCREMENT PRIMARY KEY,
    log TEXT NOT NULL,
    transaction_id VARCHAR(255),
    event_id VARCHAR(255)
);

INSERT INTO log_entries (log, transaction_id, event_id) VALUES
('User login', 'TX123', 'EVT001'),
('File uploaded', 'TX124', 'EVT002'),
('User logout', 'TX125', 'EVT003');
EOF
)

# Run SQL commands
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -e "$SQL_COMMANDS"

echo "Database 'logs' and table 'log_entries' seeded successfully."
