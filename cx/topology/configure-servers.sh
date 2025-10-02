#!/bin/bash

set -euo pipefail

TOPO_NS=${TOPO_NS:-eda-netbox}
CORE_NS=${CORE_NS:-eda-system}

servers=(server1 server2)

echo "Waiting for simulation links to be created"
for link in leaf1-ethernet-1-1 leaf2-ethernet-1-1; do
  kubectl -n "${TOPO_NS}" wait --for=create simlink "${link}" --timeout=120s
done

for server in "${servers[@]}"; do
  echo "Waiting for interfaces on ${server}"
  kubectl -n "${CORE_NS}" exec \
    $(kubectl get -n "${CORE_NS}" pods -l "eda.nokia.com/app=sim-${server}" -o jsonpath="{.items[0].metadata.name}") \
    -c "${server}" -- bash -c "$(cat configs/servers/wait-for-ifaces.sh)"
done

for server in "${servers[@]}"; do
  echo "Configuring ${server}"
  kubectl -n "${CORE_NS}" exec \
    $(kubectl get -n "${CORE_NS}" pods -l "eda.nokia.com/app=sim-${server}" -o jsonpath="{.items[0].metadata.name}") \
    -c "${server}" -- bash -c "$(cat configs/servers/${server}.sh)"
done
