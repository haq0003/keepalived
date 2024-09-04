#!/bin/bash

# Failover IP to be switched
FAILOVER_IP="XX.XX.XX.88"

# Online.net API credentials (replace with your actual token)
API_TOKEN="XXXXXX"

# Define the IPs of the servers
M02_IP="YY.YY.YY.116"
M03_IP="YY.YY.YY.49"

# Log file for debugging
LOG_FILE="/var/log/failover_script.log"

# Retry limit and exponential backoff configuration
RETRY_MAX=5
SLEEP_INTERVAL=5

# Utility function to log messages with timestamps
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Function to null-route the failover IP with retry logic
null_route_ip() {
    local retry_count=0
    while [[ $retry_count -lt $RETRY_MAX ]]; do
        log_message "Null-routing failover IP $FAILOVER_IP (attempt $((retry_count+1))/$RETRY_MAX)..."
        NULL_ROUTE_RESPONSE=$(curl -s -X POST "https://api.online.net/api/v1/server/failover/edit" \
            -H "Authorization: Bearer $API_TOKEN" \
            -d "source=$FAILOVER_IP&destination=")

        log_message "Null Route Response: $NULL_ROUTE_RESPONSE"

        # Handle already deprovisioned case gracefully
        if [[ "$NULL_ROUTE_RESPONSE" == *"Address already deprovisioned"* ]]; then
            log_message "Failover IP is already deprovisioned (null-routed), proceeding."
            break
        elif [[ "$NULL_ROUTE_RESPONSE" == "true" ]]; then
            log_message "Null-routing completed successfully."
            break
        else
            log_message "Failed to null-route the failover IP, retrying in $SLEEP_INTERVAL seconds..."
            retry_count=$((retry_count + 1))
            sleep $SLEEP_INTERVAL
            SLEEP_INTERVAL=$((SLEEP_INTERVAL * 2))  # Exponential backoff
        fi
    done

    # Exit if we exhausted retries without success
    if [[ $retry_count -ge $RETRY_MAX ]]; then
        log_message "Failed to null-route IP after $RETRY_MAX attempts, aborting."
        exit 1
    fi
}

# Function to assign the failover IP to a destination server with retry logic
assign_failover_ip() {
    local DESTINATION_IP=$1
    local retry_count=0
    SLEEP_INTERVAL=5  # Reset sleep interval for assignment retries

    while [[ $retry_count -lt $RETRY_MAX ]]; do
        log_message "Attempting to assign failover IP $FAILOVER_IP to server $DESTINATION_IP (attempt $((retry_count+1))/$RETRY_MAX)..."

        ASSIGN_RESPONSE=$(curl -s -X POST "https://api.online.net/api/v1/server/failover/edit" \
            -H "Authorization: Bearer $API_TOKEN" \
            -d "source=$FAILOVER_IP&destination=$DESTINATION_IP")

        log_message "API Response: $ASSIGN_RESPONSE"

        # Check if the assignment was successful by comparing the response directly
        if [[ "$ASSIGN_RESPONSE" == "true" ]]; then
            log_message "IP failover successfully assigned to $DESTINATION_IP"
            return 0
        else
            log_message "Failed to assign IP failover, retrying in $SLEEP_INTERVAL seconds..."
            retry_count=$((retry_count + 1))
            sleep $SLEEP_INTERVAL
            SLEEP_INTERVAL=$((SLEEP_INTERVAL * 2))  # Exponential backoff
        fi
    done

    log_message "Failed to assign IP failover after $RETRY_MAX retries."
    exit 1
}

# Determine if the server should hold the IP (i.e., it is in MASTER state)
is_master() {
    [[ "$1" == "MASTER" ]]
}

# Handle MASTER and BACKUP states
handle_failover() {
    local state=$1

    # First, null-route any previous failover IP assignment
    null_route_ip

    if is_master "$state"; then
        # Get the current server IP
        DESTINATION_IP=$(hostname -I | awk '{print $1}')
        if [[ "$DESTINATION_IP" != "$M02_IP" && "$DESTINATION_IP" != "$M03_IP" ]]; then
            log_message "Unknown server state, cannot assign failover IP."
            exit 1
        fi

        # Assign the failover IP to this server (MASTER)
        assign_failover_ip "$DESTINATION_IP"
    else
        log_message "Server is in BACKUP state, failover IP is null-routed."
        # In BACKUP state, no need to assign the failover IP.
    fi
}

# Main script execution based on Keepalived state
case "$1" in
    "MASTER")
        log_message "Server is in MASTER state."
        handle_failover "MASTER"
        ;;
        
    "BACKUP")
        log_message "Server is in BACKUP state."
        handle_failover "BACKUP"
        ;;
        
    "FAULT")
        log_message "Server is in FAULT state, no action taken."
        ;;
        
    *)
        log_message "Unknown state: $1"
        exit 1
        ;;
esac

exit 0
