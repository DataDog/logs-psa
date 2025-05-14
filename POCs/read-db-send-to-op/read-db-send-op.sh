#!/bin/bash

# Database details
DB_HOST="localhost"
DB_USER="root"
DB_PASS="password"
DB_NAME="logs"
TABLE_NAME="log_entries"
COUNT_KEY="event_id"

# Get the last event ID from the file
if [[ ! -f event.txt ]]; then
    echo "0" > event.txt
fi
LAST_EVENT=$(< event.txt)

# URL to send data to
ENDPOINT_URL="https://your.op.endpoint/"

# Connect to MySQL and read results
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -B -e "$QUERY"

while IFS=$'\t' read -r id log transaction_id event_id; do
    # Skip header
    if [[ "$id" == "id" ]]; then
        continue
    fi

    # Send data to endpoint (adjust JSON structure as needed)
    curl -X POST "$ENDPOINT_URL" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"$id\", \"log\": \"$log\", \"transaction_id\": \"$transaction_id\"}"

    echo "Sent: id=$id, name=$name, email=$email"

    LAST_EVENT = $event_id
    done < <(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$QUERY")
done
