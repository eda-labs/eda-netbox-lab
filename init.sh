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
DEFAULT_USER_NS=eda

usage() {
    cat <<USAGE
Usage: $0 [options]

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

ensure_uv

CX_DEP=$(kubectl get -A deployment -l eda.nokia.com/app=cx 2>/dev/null | grep eda-cx || true)

ensure_progress_deadline() {
    local deployment=$1
    local namespace=${2:-netbox}
    local deadline=${3:-1200}
    local attempts=12
    local wait_seconds=5

    for ((i=1; i<=attempts; i++)); do
        if kubectl -n "${namespace}" get deployment "${deployment}" >/dev/null 2>&1; then
            if kubectl -n "${namespace}" patch deployment "${deployment}" \
                --type merge \
                --patch "{\"spec\":{\"progressDeadlineSeconds\":${deadline}}}" >/dev/null; then
                echo "Set progressDeadlineSeconds=${deadline} for deployment ${deployment} in namespace ${namespace}."
                return 0
            fi
            echo "Warning: unable to patch progressDeadlineSeconds for deployment ${deployment} (attempt ${i}/${attempts})." >&2
        fi
        sleep "${wait_seconds}"
    done
    echo "Warning: failed to patch progressDeadlineSeconds for deployment ${deployment} in namespace ${namespace}." >&2
    return 1
}

if [[ -n "$CX_DEP" ]]; then
    echo -e "${GREEN}--> EDA CX environment detected. Using CX resources.${RESET}"
    IS_CX=true

    edactl() {
        kubectl -n eda-system exec \
            $(kubectl -n eda-system get pods -l eda.nokia.com/app=eda-toolbox -o jsonpath="{.items[0].metadata.name}") \
            -- edactl "$@"
    }

    echo -e "${GREEN}--> Bootstrapping namespace ${ST_STACK_NS}...${RESET}"
    if ! edactl namespace bootstrap create --from-namespace eda ${ST_STACK_NS} | indent_out; then
        echo "Warning: namespace bootstrap reported an issue; continuing." >&2
    fi
else
    echo -e "${GREEN}Containerlab environment detected (no CX pods found).${RESET}"
    IS_CX=false

    echo "Installing/upgrading clab-connector tooling..."
    uv tool install git+https://github.com/eda-labs/clab-connector.git >/dev/null
    uv tool upgrade clab-connector >/dev/null

    kubectl get namespace ${ST_STACK_NS} >/dev/null 2>&1 || kubectl create namespace ${ST_STACK_NS}
fi

echo "Adding NetBox helm repository..."
helm repo add netbox https://netbox-community.github.io/netbox-chart/ --force-update --insecure-skip-tls-verify
helm repo update netbox >/dev/null

if helm list -n netbox | grep -q netbox-server; then
    echo "NetBox is already installed. Upgrading..."
    helm upgrade netbox-server netbox/netbox \
        --namespace=netbox \
        -f configs/netbox-values.yaml \
        --set postgresql.auth.password=netbox123 \
        --set redis.auth.password=netbox123 \
        --set superuser.password=netbox \
        --set superuser.apiToken=0123456789abcdef0123456789abcdef01234567 \
        --set service.type=LoadBalancer \
        --set enforceGlobalUnique=false \
        --set global.security.allowInsecureImages=true \
        --set postgresql.image.repository=bitnamilegacy/postgresql \
        --set postgresql.image.tag=17.5.0-debian-12-r9 \
        --set valkey.image.repository=bitnamilegacy/valkey \
        --set valkey.image.tag=8.1.3-debian-12-r3 \
        --version 6.0.52 >/dev/null
else
    echo "Installing NetBox helm chart..."
    helm install netbox-server netbox/netbox \
        --create-namespace \
        --namespace=netbox \
        -f configs/netbox-values.yaml \
        --set postgresql.auth.password=netbox123 \
        --set redis.auth.password=netbox123 \
        --set superuser.password=netbox \
        --set superuser.apiToken=0123456789abcdef0123456789abcdef01234567 \
        --set service.type=LoadBalancer \
        --set enforceGlobalUnique=false \
        --set global.security.allowInsecureImages=true \
        --set postgresql.image.repository=bitnamilegacy/postgresql \
        --set postgresql.image.tag=17.5.0-debian-12-r9 \
        --set valkey.image.repository=bitnamilegacy/valkey \
        --set valkey.image.tag=8.1.3-debian-12-r3 \
        --version 6.0.52 >/dev/null
fi

ensure_progress_deadline netbox-server
ensure_progress_deadline netbox-server-worker

echo "Waiting for NetBox pods to be ready (this can take up to 15 minutes, check kubectl get pods -n netbox)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=netbox \
    --field-selector=status.phase!=Succeeded -n netbox --timeout=900s >/dev/null

SERVICE_TYPE=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.spec.type}')
echo "NetBox service type: $SERVICE_TYPE"

NETBOX_URL=""
if [[ "$SERVICE_TYPE" == "LoadBalancer" ]]; then
    echo "Waiting for NetBox LoadBalancer address..."
    for attempt in {1..30}; do
        ADDR=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [[ -z "$ADDR" ]]; then
            ADDR=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        fi
        if [[ -n "$ADDR" ]]; then
            NETBOX_URL="http://${ADDR}"
            echo "LoadBalancer reachable at: $NETBOX_URL"
            break
        fi
        echo "Waiting for external address... (attempt ${attempt}/30)"
        sleep 10
    done
fi

if [[ -z "$NETBOX_URL" ]]; then
    pkill -f "kubectl port-forward.*netbox-server.*8001" 2>/dev/null || true
    SERVICE_PORT=$(kubectl get svc -n netbox netbox-server -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    echo "Starting NetBox port-forward on 8001..."
    nohup kubectl port-forward -n netbox service/netbox-server 8001:${SERVICE_PORT} --address=0.0.0.0 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 5
    if ps -p $PORT_FORWARD_PID >/dev/null; then
        HOST_IP=$(hostname -I | awk '{print $1}')
        NETBOX_URL="http://${HOST_IP}:8001"
        echo "NetBox port-forward active (PID $PORT_FORWARD_PID)"
    else
        echo "Port-forward failed to start; please configure manually."
        NETBOX_URL="http://localhost:8001"
    fi
fi

echo "$NETBOX_URL" > .netbox_url

EDA_API=$(uv run ./scripts/get_eda_api.py)
if [[ -z "$EDA_API" ]]; then
    echo "No EDA API address found. Exiting."
    exit 1
fi
echo "$EDA_API" > .eda_api_address

NETBOX_API_TOKEN=$(kubectl -n netbox get secret netbox-server-superuser -o jsonpath='{.data.api_token}' | base64 -d)

echo "Ensuring namespace ${ST_STACK_NS} exists..."
kubectl get namespace ${ST_STACK_NS} >/dev/null 2>&1 || kubectl create namespace ${ST_STACK_NS}

token_b64=$(echo -n "$NETBOX_API_TOKEN" | base64)
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: netbox-api-token
  namespace: ${ST_STACK_NS}
type: Opaque
data:
  apiToken: ${token_b64}
YAML

WEBHOOK_SECRET="eda-netbox-webhook-secret"
webhook_b64=$(echo -n "$WEBHOOK_SECRET" | base64)
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: netbox-webhook-signature
  namespace: ${ST_STACK_NS}
type: Opaque
data:
  signatureKey: ${webhook_b64}
YAML

echo -e "${GREEN}--> Importing Nokia device types...${RESET}"
uv run scripts/import_device_types.py | indent_out

echo -e "${GREEN}--> Applying NetBox App...${RESET}"
kubectl apply -f ./manifests/0001_netbox_app_install.yaml | indent_out

echo -e "${GREEN}--> Configuring NetBox for EDA integration...${RESET}"
uv run scripts/configure_netbox.py | indent_out

echo -e "${GREEN}--> Applying NetBox Instance manifest...${RESET}"
kubectl apply -f ./manifests/0010_netbox_instance.yaml | indent_out

echo -e "${GREEN}--> Applying Allocations manifest...${RESET}"
kubectl apply -f ./manifests/0020_allocations.yaml | indent_out

if [[ "$IS_CX" == "true" ]]; then
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

    echo -e "${GREEN}--> Waiting for CX nodes to reach Synced state...${RESET}"
    kubectl -n ${ST_STACK_NS} wait --for=jsonpath='{.status.node-state}'=Synced \
        toponode --all --timeout=300s | indent_out

    echo -e "${GREEN}--> Configuring CX server containers...${RESET}"
    bash ./cx/topology/configure-servers.sh | indent_out
fi

echo -e "${GREEN}--> Applying Fabric manifest...${RESET}"
kubectl apply -f ./manifests/0060_fabric.yaml | indent_out

echo ""
if [[ "$IS_CX" == "true" ]]; then
    echo "CX topology ready. Helpers:"
    echo "  ./cx/node-ssh <node>"
    echo "  ./cx/container-shell <server>"
else
    echo "Next steps for containerlab deployment:"
    echo "  1. containerlab deploy -t eda-nb.clab.yaml"
    echo "  2. clab-connector integrate \\
       --topology-data clab-eda-nb/topology-data.json \\
       --eda-url \"https://$(cat .eda_api_address)\" \\
       --namespace ${ST_STACK_NS} \\
       --skip-edge-intfs"
fi

echo ""
echo "==================================="
echo "NetBox installation completed!"
echo "==================================="
echo "NetBox URL: $NETBOX_URL"
echo "Username: admin"
echo "Password: netbox"
echo ""
echo "If you cannot reach NetBox, use port-forward:"
echo "  kubectl -n netbox port-forward svc/netbox-server --address 0.0.0.0 8080:80"
echo "  Then access: http://localhost:8080"
