#!/bin/bash

# Wait up to 120 seconds for eth1 to become available.
timeout=120
elapsed=0
while [ $elapsed -lt $timeout ]; do
    if ip link show eth1 >/dev/null 2>&1; then
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ $elapsed -ge $timeout ]; then
    echo "Error: eth1 interface did not appear within ${timeout}s"
    exit 1
fi
