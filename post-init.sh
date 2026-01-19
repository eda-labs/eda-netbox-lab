#!/bin/bash

set -euo pipefail

ensure_uv() {
    if ! command -v uv >/dev/null 2>&1; then
        echo "Installing uv runtime..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    fi
}

indent_out() { sed 's/^/    /'; }

GREEN="\033[0;32m"
RESET="\033[0m"

ST_STACK_NS=eda-netbox

usage() {
    cat <<USAGE
Usage: $0 [options]

Run this script AFTER init.sh has completed and device types have been imported into NetBox.
This script applies fabric manifests and deploys the CX topology.

Options:
  -h, --help    Show this help message.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Check prerequisites
if [[ ! -f .netbox_url ]]; then
    echo "Error: .netbox_url not found. Run init.sh first."
    exit 1
fi

if [[ ! -f .eda_api_address ]]; then
    echo "Error: .eda_api_address not found. Run init.sh first."
    exit 1
fi

NETBOX_URL=$(cat .netbox_url)
NETBOX_API_TOKEN=$(kubectl -n netbox get secret netbox-server-superuser -o jsonpath='{.data.api_token}' | base64 -d)

# Check if CX environment
CX_DEP=$(kubectl get -A deployment -l eda.nokia.com/app=cx 2>/dev/null | grep eda-cx || true)

if [[ -n "$CX_DEP" ]]; then
    IS_CX=true
    echo -e "${GREEN}--> EDA CX environment detected.${RESET}"
else
    IS_CX=false
    echo -e "${GREEN}--> Containerlab environment detected.${RESET}"
fi

# Verify device types exist in NetBox
echo "Checking for device types in NetBox..."
DEVICE_TYPE_COUNT=$(curl -s -H "Authorization: Token ${NETBOX_API_TOKEN}" \
    "${NETBOX_URL}/api/dcim/device-types/" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo 0)

if [[ "$DEVICE_TYPE_COUNT" -eq 0 ]]; then
    echo "Warning: No device types found in NetBox."
    echo "Consider running: init.sh --import-nokia-device-types"
    exit 1
fi

echo "Found ${DEVICE_TYPE_COUNT} device types in NetBox"

ensure_uv

echo -e "${GREEN}--> Configuring NetBox for EDA integration...${RESET}"
uv run scripts/configure_netbox.py | indent_out

echo -e "${GREEN}--> Applying NetBox Instance manifest...${RESET}"
kubectl apply -f ./manifests/0010_netbox_instance.yaml | indent_out


echo -e "${GREEN}--> Applying Allocations manifest...${RESET}"
kubectl apply -f ./manifests/0020_allocations.yaml | indent_out

# Check if topology already exists
EXISTING_TOPO=$(kubectl -n ${ST_STACK_NS} get topology -o name 2>/dev/null || true)

if [[ -z "$EXISTING_TOPO" ]]; then
    echo -e "${GREEN}--> Deploying CX topology...${RESET}"
    TOPO_OUTPUT=$(kubectl -n ${ST_STACK_NS} create -f ./cx/topology/lab-topo.yaml)
    TOPO_NAME=$(echo "$TOPO_OUTPUT" | awk '{print $1}')
    echo "Created topology resource: ${TOPO_NAME}" | indent_out
    echo "Waiting for topology deployment to complete..."
    if ! kubectl -n ${ST_STACK_NS} wait --for=jsonpath='{.status.result}'=Success "$TOPO_NAME" --timeout=300s; then
        echo "Topology deployment failed. Checking status..." >&2
        kubectl -n ${ST_STACK_NS} get "$TOPO_NAME" -o jsonpath='{.status}' >&2
        exit 1
    fi
    echo "Topology deployment successful" | indent_out
else
    echo "Topology already exists: ${EXISTING_TOPO}" | indent_out
fi

echo -e "${GREEN}--> Waiting for CX nodes to reach Synced state...${RESET}"
kubectl -n ${ST_STACK_NS} wait --for=jsonpath='{.status.node-state}'=Synced \
    toponode --all --timeout=300s | indent_out

echo -e "${GREEN}--> Applying Fabric manifest...${RESET}"
kubectl apply -f ./manifests/0060_fabric.yaml | indent_out

echo -e "${GREEN}--> Configuring CX server containers...${RESET}"
bash ./cx/topology/configure-servers.sh | indent_out


echo ""
echo "==================================="
echo "Post-init completed!"
echo "==================================="
if [[ "$IS_CX" == "true" ]]; then
    echo "CX topology ready. Helpers:"
    echo "  ./cx/node-ssh <node>"
    echo "  ./cx/container-shell <server>"
else
    echo "Next steps for containerlab deployment:"
    echo "  1. Deploy containerlab topology if not done"
    echo "  2. Use clab-connector to integrate devices"
fi
