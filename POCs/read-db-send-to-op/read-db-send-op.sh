#!/bin/bash

# Database credentials
DB_HOST="localhost"
DB_USER="your_user"
DB_PASS="your_password"
DB_NAME="your_database"

# Query to run
QUERY="SELECT id, name, email FROM users;"

# URL to send data to
ENDPOINT_URL="https://your.api.endpoint/receive"

# Connect to MySQL and read results
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -B -e "$QUERY" | while IFS=$'\t' read -r id name email; do
    # Skip header
    if [[ "$id" == "id" ]]; then
        continue
    fi

    # Send data to endpoint (adjust JSON structure as needed)
    curl -X POST "$ENDPOINT_URL" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"$id\", \"name\": \"$name\", \"email\": \"$email\"}"

    echo "Sent: id=$id, name=$name, email=$email"
done
