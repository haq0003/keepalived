#!/bin/bash


# Load environment variables from the file
if [[ -f /etc/keepalived/keepalived_env ]];  then
    source /etc/keepalived/keepalived_env
fi


# Log file for debugging
LOG_FILE="/var/log/failover_script.log"

# Utility function to log messages with timestamps
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a $LOG_FILE
}

# Function to check if the failover IP is already assigned to another server
check_ip_assignment() {
    log_message "Checking current status of failover IP $FAILOVER_IP"
    CHECK_STATUS=$(curl -s -X GET "https://api.online.net/api/v1/server/failover/$FAILOVER_IP" \
        -H "Authorization: Bearer $API_TOKEN")

    if [[ $? -ne 0 ]]; then
        log_message "Error: Unable to reach the API. Please check network connectivity."
        exit 1
    fi

    # Extract the destination from the first object in the array
    ASSIGNED_TO=$(echo "$CHECK_STATUS" | jq -r '.[0].destination')

    if [[ "$ASSIGNED_TO" == "null" ]]; then
        log_message "Failover IP is not assigned to any server."
        return 1
    elif [[ "$ASSIGNED_TO" == "$M02_IP" || "$ASSIGNED_TO" == "$M03_IP" ]]; then
        log_message "Failover IP is currently assigned to $ASSIGNED_TO."
        return 0
    else
        log_message "Unexpected response or error assigning failover IP. Response: $CHECK_STATUS"
        return 1
    fi
}

# Function to null-route the failover IP (unassign)
null_route_ip() {
    log_message "Null-routing failover IP $FAILOVER_IP..."
    NULL_ROUTE_RESPONSE=$(curl -s -X POST "https://api.online.net/api/v1/server/failover/edit" \
        -H "Authorization: Bearer $API_TOKEN" \
        -d "source=$FAILOVER_IP&destination=")

    log_message "Null Route Response: $NULL_ROUTE_RESPONSE"
    if [[ "$NULL_ROUTE_RESPONSE" == *"Address already deprovisioned"* ]]; then
        log_message "Failover IP is already deprovisioned (null-routed), proceeding."
    elif [[ "$NULL_ROUTE_RESPONSE" != "true" ]]; then
        log_message "Failed to null-route the failover IP. Response: $NULL_ROUTE_RESPONSE"
        exit 1
    else
        log_message "Null-routing completed successfully."
    fi
}

# Function to assign the failover IP to a destination server
assign_failover_ip() {
    local DESTINATION_IP=$1
    RETRY_ASSIGN_MAX=5
    RETRY_ASSIGN_COUNT=0
    SLEEP_INTERVAL=5

    while [[ $RETRY_ASSIGN_COUNT -lt $RETRY_ASSIGN_MAX ]]; do
        log_message "Attempting to assign failover IP $FAILOVER_IP to server $DESTINATION_IP..."

        ASSIGN_RESPONSE=$(curl -s -X POST "https://api.online.net/api/v1/server/failover/edit" \
            -H "Authorization: Bearer $API_TOKEN" \
            -d "source=$FAILOVER_IP&destination=$DESTINATION_IP")

        log_message "API Response: $ASSIGN_RESPONSE"

        if [[ "$ASSIGN_RESPONSE" == "true" ]]; then
            log_message "IP failover successfully assigned to $DESTINATION_IP"
            return 0
        else
            log_message "Failed to assign IP failover, retrying in $SLEEP_INTERVAL seconds... Response: $ASSIGN_RESPONSE"
            RETRY_ASSIGN_COUNT=$((RETRY_ASSIGN_COUNT + 1))
            sleep $SLEEP_INTERVAL
            SLEEP_INTERVAL=$((SLEEP_INTERVAL * 2))  # Exponential backoff
        fi
    done

    log_message "Failed to assign IP failover after $RETRY_ASSIGN_MAX attempts."
    exit 1
}

# Determine if the server should hold the IP (i.e., it is in MASTER state)
is_master() {
    [[ "$1" == "MASTER" ]]
}

# Handle MASTER and BACKUP states
handle_failover() {
    local state=$1

    if is_master "$state"; then
        # Get the current server IP
        DESTINATION_IP=$(hostname -I | awk '{print $1}')
        if [[ "$DESTINATION_IP" != "$M02_IP" && "$DESTINATION_IP" != "$M03_IP" ]]; then
            log_message "Unknown server state ($DESTINATION_IP), cannot assign failover IP."
            exit 1
        fi

        # Assign the failover IP to this server (MASTER)
        assign_failover_ip "$DESTINATION_IP"
    else
        # Before null-routing, check if another server is already MASTER and holding the IP
        check_ip_assignment
        if [[ $? -eq 1 ]]; then
            # Only null-route if no server is holding the IP
            null_route_ip
        else
            log_message "Another server is holding the failover IP. Not null-routing."
        fi
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
