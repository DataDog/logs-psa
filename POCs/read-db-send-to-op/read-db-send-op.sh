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
ENDPOINT_URL="http://localhost:9997/"

END_TIME=$((SECONDS + 60))

# loop for 60 seconds, but can be adjusted
# this would work nicely for a cron job that runs every minute
while [ "$SECONDS" -lt "$END_TIME" ]; do

    # DEBUG
    # echo "Last event ID: $LAST_EVENT"

    echo "Sent: id=$id, name=$name, email=$email"

    LAST_EVENT = $event_id
    done < <(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "$QUERY")
done
