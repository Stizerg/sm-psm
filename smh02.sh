#!/bin/bash
cd ~/spacemesh/

# Start the service and capture its PID
./post-service --dir ./smh02 --address http://192.168.1.6:9094 --operator-address 0.0.0.0:50002 --threads 0 --nonces 224 > >(tee -a ./smh02.log) 2>&1 &
SERVICE_PID=$!

# Write the PID to a file
echo $SERVICE_PID > ./smh02.pid

# Output the PID to the console
echo "Started post-service with PID: $SERVICE_PID"

# Wait for the service to finish
wait $SERVICE_PID
