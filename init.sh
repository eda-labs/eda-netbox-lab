#!/bin/bash

function install-uv {
    # error if uv is not in the path
    if ! command -v uv &> /dev/null;
    then
        echo "Installing uv";
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
}

# Install uv and clab-connector
install-uv
uv tool install git+https://github.com/eda-labs/clab-connector.git
uv tool upgrade clab-connector

# Add NetBox helm repo if not already added
echo "Adding NetBox helm repository..."
helm repo add netbox https://netbox-community.github.io/netbox-chart/ 2>/dev/null || true
helm repo update

# Check if NetBox is already installed
if helm list -n netbox | grep -q netbox-server; then
    echo "NetBox is already installed. Upgrading..."
    helm upgrade netbox-server netbox/netbox \
        --namespace=netbox \
        --set postgresql.auth.password=netbox123 \
        --set redis.auth.password=netbox123 \
        --set superuser.password=netbox \
        --set superuser.apiToken=0123456789abcdef0123456789abcdef01234567 \
        --set service.type=LoadBalancer \
        --set enforceGlobalUnique=false \
        --version 6.0.52
else
    echo "Installing NetBox helm chart..."
    helm install netbox-server netbox/netbox \
        --create-namespace \
        --namespace=netbox \
        --set postgresql.auth.password=netbox123 \
        --set redis.auth.password=netbox123 \
        --set superuser.password=netbox \
        --set superuser.apiToken=0123456789abcdef0123456789abcdef01234567 \
        --set service.type=LoadBalancer \
        --set enforceGlobalUnique=false \
        --version 6.0.52
fi

# Wait for NetBox to be ready
echo "Waiting for NetBox pods to be ready..."
echo "Note: First-time deployment may take several minutes while downloading container images."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=netbox --field-selector=status.phase!=Succeeded -n netbox --timeout=600s

# Get NetBox service info
echo "Checking NetBox service type..."
SERVICE_TYPE=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.spec.type}' 2>/dev/null)
echo "Service type: $SERVICE_TYPE"

if [ "$SERVICE_TYPE" == "LoadBalancer" ]; then
    echo "Waiting for NetBox LoadBalancer to get external IP..."
    NETBOX_IP=""
    RETRY_COUNT=0
    MAX_RETRIES=30
    
    while [ -z "$NETBOX_IP" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        NETBOX_IP=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -z "$NETBOX_IP" ]; then
            # Also check for hostname (some cloud providers use hostname instead of IP)
            NETBOX_IP=$(kubectl get svc netbox-server -n netbox -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        fi
        if [ -z "$NETBOX_IP" ]; then
            echo "Waiting for external IP... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
            sleep 10
            RETRY_COUNT=$((RETRY_COUNT+1))
        fi
    done
    
    if [ -n "$NETBOX_IP" ]; then
        echo "Got NetBox external IP/hostname: $NETBOX_IP"
        NETBOX_URL="http://$NETBOX_IP"
    else
        echo "Warning: LoadBalancer IP not assigned. Falling back to port-forward."
        SERVICE_TYPE="ClusterIP"
    fi
fi

if [ "$SERVICE_TYPE" != "LoadBalancer" ] || [ -z "$NETBOX_IP" ]; then
    # Kill any existing port-forwards
    pkill -f "kubectl port-forward.*netbox-server.*8001" 2>/dev/null || true
    
    # Get the actual service port
    SERVICE_PORT=$(kubectl get svc -n netbox netbox-server -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
    
    # Use port-forward for ClusterIP or if LoadBalancer failed
    echo "Starting NetBox port-forward on port 8001..."
    nohup kubectl port-forward -n netbox service/netbox-server 8001:${SERVICE_PORT} --address=0.0.0.0 >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!
    sleep 5
    
    # Check if port-forward is running
    if ps -p $PORT_FORWARD_PID > /dev/null; then
        echo "NetBox port-forward started successfully (PID: $PORT_FORWARD_PID)"
        NETBOX_URL="http://$(hostname -I | awk '{print $1}'):8001"
        echo "NetBox is accessible at: $NETBOX_URL"
        echo "Or via: http://localhost:8001 (from this machine)"
    else
        echo "Error: Port-forward failed to start. Please run manually:"
        echo "kubectl port-forward -n netbox service/netbox-server 8001:${SERVICE_PORT} --address=0.0.0.0"
        NETBOX_URL="http://localhost:8001"
    fi
fi

# Save NetBox URL for later use
echo "$NETBOX_URL" > .netbox_url

# Fetch EDA ext domain name from engine config
EDA_API=$(uv run ./scripts/get_eda_api.py)

# Ensure input is not empty
if [[ -z "$EDA_API" ]]; then
  echo "No EDA API address found. Exiting."
  exit 1
fi

# Save EDA API address to a file
echo "$EDA_API" > .eda_api_address

# Get NetBox API token
echo "Getting NetBox API token..."
NETBOX_API_TOKEN=$(kubectl -n netbox get secret netbox-server-superuser -o jsonpath='{.data.api_token}' | base64 -d)

# Create Kubernetes secrets for NetBox integration
echo "Creating Kubernetes secrets for NetBox integration..."

# Create namespace if it doesn't exist
kubectl create namespace clab-eda-nb 2>/dev/null || true

# Create NetBox API token secret
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: netbox-api-token
  namespace: clab-eda-nb
type: Opaque
data:
  apiToken: $(echo -n "$NETBOX_API_TOKEN" | base64)
EOF

# Create webhook signature secret
WEBHOOK_SECRET="eda-netbox-webhook-secret"
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: netbox-webhook-signature
  namespace: clab-eda-nb
type: Opaque
data:
  signatureKey: $(echo -n "$WEBHOOK_SECRET" | base64)
EOF

# Configure NetBox automatically
echo ""
echo "Configuring NetBox for EDA integration..."
uv run scripts/configure_netbox.py

echo ""
echo "==================================="
echo "NetBox installation completed!"
echo "==================================="
echo ""
echo "NetBox Access:"
echo "  URL: $NETBOX_URL"
echo "  Username: admin"
echo "  Password: netbox"
echo ""
if [ "$SERVICE_TYPE" != "LoadBalancer" ] || [ -z "$NETBOX_IP" ]; then
    echo "Note: Using port-forward to access NetBox"
    echo "  - For Kind/local clusters, you may need additional port-forwarding from your host"
    echo "  - To restart port-forward: kubectl port-forward -n netbox service/netbox-server 8001:80 --address=0.0.0.0"
fi
echo ""
echo "Next steps:"
echo "1. Deploy the containerlab topology: sudo containerlab deploy -t eda-nb.clab.yaml"
echo "2. Import topology to EDA: clab-connector import -t eda-nb.clab.yaml"
echo "3. Apply EDA resources: kubectl apply -f manifests/"
