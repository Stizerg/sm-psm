#!/bin/bash

version="1.01"

#Starts/stops all services for a test. Doesn't run during cycle gap
test=0 # Set to 1 to test.

max_POW=1 # Maximum number of services proving POW (stage 1) at the same time
max_Services=99 # Maximum number of all services working at the same time

psm_log_level=3
log_levels='{
    "0": "FATAL",
    "1": "ERROR",
    "2": "WARN",
    "3": "INFO",
    "4": "DEBUG"
}'
log_file="./logs/sm-psm.log"

# Configuration file
ConfigFile="sm-psm-config.txt"

# Declare associative arrays
declare -A node_config
declare -A service_configs
declare -a service_order

function send_log {
    local time_stamp=$(date '+%Y-%m-%d %H:%M:%S')
    local function_name=${FUNCNAME[1]}
    local log_message
    local message=$2
    local message_log_level=$1
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "FATAL: jq is not installed." >&2
        read -n 1 -s -r -p "Press any key to continue ..."
	exit 1
    fi
    local log_level=$(echo $log_levels | jq -r ".[\"$message_log_level\"]")    

    if (( $message_log_level <= $psm_log_level )); then
    	if (( $psm_log_level <= 3)); then
    		local log_message=$(printf "%-20s %-5s %s\n" "${time_stamp}" "${log_level}" "${message}")
    	else
        	local log_message=$(printf "%-20s %-5s %-20s %s\n" "${time_stamp}" "${log_level}" "[${function_name}]" "${message}")
        fi
        echo "$log_message" >&2
        echo "$log_message" >> "$log_file"
    fi
}

function trim_space {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"   
    printf '%s' "$var"
}

function load_configuration {
    local line_number=0
    while IFS= read -r line; do
        line=${line%%#*}
        line=$(trim_space "$line")
        [ -z "$line" ] && continue
        
        IFS=',' read -ra fields <<< "$line"
        
        # Trim spaces for each field
        name=$(trim_space "${fields[0]}")
        ip=$(trim_space "${fields[1]}")
        port1=$(trim_space "${fields[2]}")
        port2=$(trim_space "${fields[3]}")
        port3=$(trim_space "${fields[4]}")
        su=$(trim_space "${fields[5]}")
        
        su=${su:-0}
        
        if [ $line_number -eq 0 ]; then
            node_config["name"]=$name
            node_config["ip"]=$ip
            node_config["port1"]=$port1
            node_config["port2"]=$port2
            node_config["port3"]=$port3
            node_config["su"]=$su
        else
            service_configs["$name"]="$ip,$port1,$port2,$port3,$su"
            service_order+=("$name")
        fi
        ((line_number++))
    done < "$ConfigFile"
    
    send_log 3 "Configuration loaded successfully"
    send_log 4 "Node Config: ${node_config[@]}"
    send_log 4 "Services processing order: ${service_order[*]}"
}

function check_grpcurl {
    # Set the path to the local grpcurl copy
    grpcurl="./grpcurl"
    
    # Check if the local grpcurl exists
    if [ ! -f "$grpcurl" ]; then
        grpcurl_path=$(which grpcurl)

        if [ -z "$grpcurl_path" ]; then
            send_log 0 "grpcurl not found"
            read -n 1 -s -r -p "Press any key to continue ..."
            exit 1
        else
            grpcurl=$grpcurl_path
        fi
    fi
    send_log 4 "using grpcurl located at ${grpcurl}"
}

function check_node_status { 
    local command="${grpcurl} -plaintext ${node_config[ip]}:${node_config[port1]} spacemesh.v1.NodeService.Status"
    
    local response
    response=$(eval "$command" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
    	check_grpcurl=4
        send_log 1 "Failed to get node status =${node_config[name]}=. Error: $response"
        return 1
    fi
    
    local is_synced
    is_synced=$(echo "$response" | jq -r '.status.isSynced')
    
    if [ "$is_synced" = "true" ]; then
        send_log 3 "Node is synced =${node_config[name]}="
        return 0
    else
        send_log 2 "Node is not synced =${node_config[name]}="
        return 1
    fi
}

function get_post_states {
    local response
    response=$(${grpcurl} --plaintext ${node_config["ip"]}:${node_config["port3"]} spacemesh.v1.PostInfoService.PostStates 2>/dev/null)
    if [ $? -ne 0 ]; then
        send_log 2 "Failed to get post states"
        return 1
    fi
    
    echo "$response" | jq -c '.states[]'
}

function is_service_running {
    local service_name="$1"
    local base_name=${service_name%.key}
    local pid_file="./${base_name}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0  # Service is running
        else
            send_log 2 "PID file exists for $service_name, but process is not running"
            rm "$pid_file"  # Remove stale PID file
        fi
    fi
    
    return 1  # Service is not running
}

function check_service_status {
    local service_name=$1
    local ip port3
    local su
    IFS=',' read -r ip _ _ port3 su <<< "${service_configs[$service_name]}"
    local ServiceStatus="http://$ip:$port3/status"
    
    # Check if the process is running
    if ! is_service_running "$service_name"; then
        send_log 4 "Process for ${service_name} is not running"
        echo "OFFLINE"
        return 0
    fi

    send_log 4 "Process for ${service_name} is running. Attempting to fetch status from: ${ServiceStatus}"
    local response
    response=$(curl -s -m 5 --fail "${ServiceStatus}" 2>&1)
    local curl_exit_code=$?
    
    if [ $curl_exit_code -ne 0 ]; then
        send_log 1 "Failed to get status for ${service_name}. Curl exit code: ${curl_exit_code}. Error: ${response}"
        echo "OFFLINE"
        return 0
    fi
    
    send_log 4 "Raw status response for ${service_name}: ${response}"
    response=$(echo "$response" | sed -e 's/^"//' -e 's/"$//')
    
    # Check if the response is a simple string
    if [[ "$response" =~ ^[A-Za-z]+$ ]]; then
        case "$response" in
            "Idle")
                echo "IDLE"
                ;;
            "DoneProving")
            	echo "DONE"
            	;;
            "Proving")
                echo "Proving_POW"
                ;;
            *)
                send_log 2 "Unknown status for ${service_name}: ${response}"
                echo "UNKNOWN"
                ;;
        esac
    else
        # Attempt to parse as JSON
        local parsed_response
        parsed_response=$(echo "$response" | jq -r '.' 2>/dev/null)
        local jq_exit_code=$?

        if [ $jq_exit_code -ne 0 ]; then
            send_log 2 "Invalid JSON response for ${service_name}: ${response}"
            echo "UNKNOWN"
        else
            # Valid JSON response
            if echo "$parsed_response" | jq -e 'has("Proving")' > /dev/null; then
                local position
                position=$(echo "$parsed_response" | jq -r '.Proving.position')
                if [ "$position" = "null" ]; then
                    send_log 2 "Invalid Proving status for ${service_name}: position is null"
                    echo "UNKNOWN"
                elif (( position > 0 )); then
					
					local percent
					send_log 4 "SU of $service_name: $su"
					if [ "$su" -eq 0 ]; then
						send_log 3 "Service $service_name is proving disk"
    				else
    					percent=$(bc <<< "scale=0; ($position / ($su * 68719476736)) * 100")
    					send_log 3 "Service $service_name is proving disk, progress: $percent%"
    				fi
                    echo "Proving_Disk"
                else
                	send_log 3 "Service $service_name is proving POW"
                    echo "Proving_POW"
                fi
            else
                send_log 1 "Unknown status for ${service_name}: ${parsed_response}"
                echo "UNKNOWN"
            fi
        fi
    fi
}

function start_service {
    local service_name="$1"
    send_log 4 "Attempting to start ${service_name}"
    
    # Remove the .key extension if present
    local base_name=${service_name%.key}
    
    # Try different possible script names
    local startup_script
    for script in "./${base_name}.sh" "./${service_name}.sh" "./${base_name}"; do
        if [ -f "$script" ]; then
            startup_script="$script"
            break
        fi
    done
    
    if [ -z "$startup_script" ]; then
        send_log 1 "Startup script for ${service_name} not found. Tried ${base_name}.sh, ${service_name}.sh, and ${base_name}"
        return 1
    fi
    
    send_log 4 "Using startup script: ${startup_script}"
    
    # Execute the startup script
	gnome-terminal --title="${service_name}" -- bash -c "
        ${startup_script};
        echo \$? > /tmp/${base_name}.exit_status
    " &
    
    # Wait for the service to start or the startup script to finish (up to 10 seconds)
    local wait_time=0
    while [ ! -f "/tmp/${base_name}.exit_status" ] && [ $wait_time -lt 10 ]; do
        if is_service_running "$service_name"; then
            send_log 4 "Service ${base_name} started successfully"
            rm -f "/tmp/${base_name}.exit_status" 2>/dev/null
            return 0
        fi
        sleep 1
        ((wait_time++))
    done
    
    if [ -f "/tmp/${base_name}.exit_status" ]; then
        local exit_status=$(cat "/tmp/${base_name}.exit_status")
        rm -f "/tmp/${base_name}.exit_status"
        
        # Waiting a bit to ensure the service has time to start
        sleep 2
        
        if is_service_running "$service_name"; then
            send_log 4 "Service ${base_name} started successfully"
            return 0
        else
            send_log 1 "Failed to start ${base_name}. Startup script exited with code ${exit_status}"
            return 1
        fi
    else
        if is_service_running "$service_name"; then
            send_log 4 "Service ${base_name} appears to be running now, but with some troubles"
            return 0
        fi
        send_log 1 "Failed to start ${base_name} or verify its running status within 10 seconds"
        return 1
    fi
}

function stop_service {
    local service_name="$1"
    
    # Remove the .key extension if present
    local base_name=${service_name%.key}
    
    local PID_FILE="./${base_name}.pid"
    if [ -f $PID_FILE ]; then
        local PID=$(cat $PID_FILE)
        if ps -p "$PID" > /dev/null 2>&1; then
        	send_log 4 "Stopping ${service_name} with PID ${PID}"
        	kill $PID 2>/dev/null
        	sleep 1
        	if ps -p "$PID" > /dev/null 2>&1; then
        		send_log 2 "Service ${service_name} did not stop gracefully, sending SIGTERM..."
        		kill -SIGTERM "$PID" 2>/dev/null
        		sleep 1
        	fi
        	if ps -p "$PID" > /dev/null 2>&1; then
        		send_log 2 "Service ${service_name} still running, sending SIGKILL..."
        		kill -SIGKILL "$PID" 2>/dev/null
        		sleep 1
        	fi
        
        	# Wait for the process to actually stop
			if timeout 5 kill -0 $PID 2>/dev/null; then
    			send_log 1 "Service ${service_name} could not be stopped within 5 seconds, please investigate"
			else
    			send_log 3 "Service ${service_name} has been stopped"
			fi
        	rm -f $PID_FILE
        fi
    else
        send_log 2 "PID file for ${service_name} not found, service may already be stopped"
    fi
}

function manage_services {
    post_states=$(get_post_states)
    #send_log 4 "Post states: $post_states"
    
    local node_proving_count=0 
    local node_idle_count=0
    local services_proving_count=0
    local services_idle_count=0
    local services_offline_count=0
    
    for service_name in "${service_order[@]}"; do
        local state=$(echo "$post_states" | grep -E "\"name\":\"${service_name}(\.key)?\"" | jq -c '.')
        if [ -z "$state" ]; then
            send_log 2 "Service $service_name is not found in node response"
            send_log 2 "==================================================="
            continue
        fi

        local node_reported_state=$(echo "$state" | jq -r '.state')
        send_log 4 "Processing service: $service_name, node-reported state: $node_reported_state"

        local service_actual_state=$(check_service_status "$service_name")
        send_log 4 "Service $service_name actual state: $service_actual_state"

        case "$node_reported_state" in
            "PROVING")
                ((node_proving_count++))
                case "$service_actual_state" in
					"OFFLINE")
						if (( services_proving_count < max_POW )) && (( services_proving_count + services_proving_disk_count < max_Services )); then
                    		if start_service "$service_name"; then
								send_log 3 "Successfully started service $service_name"
								service_actual_state="PROVING_POW"
								((services_proving_count++))
							else
								send_log 1 "Failed to start service $service_name. Skipping to next service."
								((services_offline_count++))
								continue
							fi
						else
							send_log 3 "Service $service_name is waiting due to maximum service limits"
							((services_offline_count++))
						fi
                		;;
					"IDLE")
						send_log 2 "Service $service_name is reported as PROVING by node, but is actually IDLE. This may indicate an issue."
						((services_idle_count++))
						;;
					"Proving_POW")
                        ((services_proving_count++))
                        ;;
                    "Proving_Disk")
                        ((services_proving_disk_count++))
                        ;;
					*)
						send_log 4 "Unexpected service state for $service_name: $service_actual_state. Node reports $node_reported_state."
						;;
				esac
				;;
            "IDLE")
                ((node_idle_count++))
                case "$service_actual_state" in
                	"IDLE")
                		stop_service "$service_name"
                		send_log 4 "Stopped idle service $service_name"
                		((services_offline_count++))
                		;;
					"Proving_POW")
                        send_log 2 "Service $service_name is reported as IDLE by node, but is actually Proving POW."
						((services_proving_count++))
                        ;;
					"Proving_Disk")
						send_log 2 "Service $service_name is reported as IDLE by node, but is actually Proving Disk."
						((services_proving_disk_count++))
						;;
                    "OFFLINE")
                        send_log 4 "Service $service_name is offline"
                        ((services_offline_count++))
                        ;;
					*)
						send_log 4 "Unexpected service state for $service_name: $service_actual_state. Node reports $node_reported_state."
						;;
                esac
                ;;
			*)
				send_log 4 "Unexpected node state $node_reported_state."
                ;;
        esac

		send_log 4 "----------------------------------------"
    done
    
    send_log 3 "Node reported - Proving: $node_proving_count, Idle: $node_idle_count"
    send_log 3 "POST services - Proving: $services_proving_count, Idle: $services_idle_count, Offline: $services_offline_count"
    
    total_active_services=$((services_proving_count + services_proving_disk_count))
    send_log 4 "Total active services: $total_active_services"
    return $node_proving_count
}

function main {    
    send_log 3 "Starting sm-psm...(version $version)"
    load_configuration
    check_grpcurl
    
    while true; do
        if check_node_status; then
            manage_services
            local nodes_proving=$?
            
            if (( total_active_services > 0 )); then
                delay=60  # 1 minute if services are running
                send_log 3 "Prooving in progress. Waiting for 1 minute."
            elif (( nodes_proving > 0 )); then
                delay=60  # 1 minute if node reports services should be proving but they're not
                send_log 2 "Node reports services should be proving but they are not. Waiting for 1 minute."
            else
        		if [ $test -eq 1 ]; then
					local tmp_psm_log_level=$psm_log_level
					psm_log_level=4
					local started_services=0
					send_log 3 "Starting services in test mode..."
					send_log 3 "All services will be stopped after 30 seconds"
					for service_name in "${service_order[@]}"; do
						if start_service "$service_name"; then
							((started_services++))
						fi
					done
                	send_log 3 "Test mode: Started $started_services services. Waiting for 30 seconds."
                	sleep 30
                	for service_name in "${service_order[@]}"; do
                    	stop_service "$service_name"
                	done
                	test=0
                	send_log 3 "Test run completed. Resuming normal operation."
                	psm_log_level=$tmp_psm_log_level
                fi
                delay=300  # 5 minutes if no services are active or should be active
                send_log 3 "No active services. Waiting for 5 minutes."
            fi
        else
            delay=300  # 5 minutes if node is not synced
            send_log 3 "Node is not synced. Waiting for 5 minutes."
        fi

        send_log 3 "Press any key to start the next cycle"
        send_log 3 "-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+"
        #sleep $delay
		read -rs -n 1 -t $delay key
    done
}

main

exit
