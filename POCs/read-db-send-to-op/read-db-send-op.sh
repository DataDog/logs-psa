#!/bin/bash

# Database credentials
DB_HOST="localhost"
DB_USER="your_user"
DB_PASS="your_password"
DB_NAME="your_database"
COUNT_KEY="event_id"

# Get the last event ID from the file
if [[ ! -f event.txt ]]; then
    echo "0" > event.txt
fi
LAST_EVENT=$(< event.txt)

# Query to run
QUERY="SELECT id, log, transaction_id, event_id FROM logs WHERE $COUNT_KEY > $LAST_EVENT ORDER BY $COUNT_KEY LIMIT 1000;"

# URL to send data to
ENDPOINT_URL="https://your.op.endpoint/"

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
