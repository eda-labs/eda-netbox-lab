#!/bin/bash

set -euo pipefail

echo "Cleaning up EDA NetBox lab..."

echo "Stopping port-forwards..."
pkill -f "kubectl port-forward.*netbox" 2>/dev/null || true

echo "Deleting EDA resources..."
if [ -d manifests ]; then
  kubectl delete -f manifests --ignore-not-found=true 2>/dev/null || true
fi

echo "Deleting secrets..."
kubectl delete secret netbox-api-token -n eda-netbox 2>/dev/null || true
kubectl delete secret netbox-webhook-signature -n eda-netbox 2>/dev/null || true

echo "Uninstalling NetBox app..."
cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: core.eda.nokia.com/v1
kind: Workflow
metadata:
  name: netbox-uninstall
  namespace: eda-system
spec:
  type: app-installer
  input:
    operation: uninstall
    apps:
      - app: netbox
        catalog: eda-catalog-builtin-apps
        vendor: nokia
YAML

sleep 10

echo "Uninstalling NetBox helm release..."
helm uninstall netbox-server -n netbox 2>/dev/null || true

echo "Deleting NetBox namespace..."
kubectl delete namespace netbox --wait=false 2>/dev/null || true

echo "Cleaning up local files..."
rm -f .netbox_url .eda_api_address

echo "Cleanup completed!"
