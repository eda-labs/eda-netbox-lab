#!/bin/bash

set -euo pipefail

ST_STACK_NS=${ST_STACK_NS:-eda-netbox}
NETBOX_NS=${NETBOX_NS:-netbox}
EDA_SYSTEM_NS=${EDA_SYSTEM_NS:-eda-system}
NETBOX_APP_VERSION=${NETBOX_APP_VERSION:-v4.0.0}

toolbox_pod() {
  kubectl -n "${EDA_SYSTEM_NS}" get pods \
    -l eda.nokia.com/app=eda-toolbox \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

have_edactl() {
  [ -n "$(toolbox_pod)" ]
}

edactl() {
  local pod
  pod=$(toolbox_pod)
  [ -n "${pod}" ] || return 1
  kubectl -n "${EDA_SYSTEM_NS}" exec "${pod}" -- edactl "$@"
}

wait_for_eda_transactions() {
  local attempts=${1:-120}
  local wait_seconds=${2:-10}
  local txns

  have_edactl || return 0

  for ((i=1; i<=attempts; i++)); do
    txns=$(edactl transaction -A --limit 30 2>/dev/null || true)
    if ! grep -Eq 'QUEUED|InProgress|PENDING|Pending|RUNNING|Running' <<<"${txns}"; then
      return 0
    fi

    echo "Waiting for EDA transactions to settle... (${i}/${attempts})"
    sleep "${wait_seconds}"
  done

  echo "Warning: EDA transactions did not settle before timeout." >&2
  return 1
}

eda_namespace_visible() {
  local namespaces stats

  have_edactl || return 1

  namespaces=$(edactl -n "${EDA_SYSTEM_NS}" get namespace.core.eda.nokia.com/v1 2>/dev/null || true)
  if awk -v ns="${ST_STACK_NS}" 'NR > 1 && $1 == ns { found = 1 } END { exit found ? 0 : 1 }' <<<"${namespaces}"; then
    return 0
  fi

  stats=$(edactl namespace stats -A 2>/dev/null || true)
  awk -v ns="${ST_STACK_NS}" 'NR > 1 && $1 == ns { found = 1 } END { exit found ? 0 : 1 }' <<<"${stats}"
}

wait_for_eda_namespace_deleted() {
  local attempts=${1:-90}
  local wait_seconds=${2:-10}

  have_edactl || return 0

  for ((i=1; i<=attempts; i++)); do
    if ! eda_namespace_visible; then
      return 0
    fi

    echo "Waiting for EDA namespace ${ST_STACK_NS} to disappear... (${i}/${attempts})"
    sleep "${wait_seconds}"
  done

  echo "Warning: EDA namespace ${ST_STACK_NS} is still visible after timeout." >&2
  return 1
}

delete_manifest_if_present() {
  local manifest=$1

  [ -f "${manifest}" ] || return 0
  kubectl delete -f "${manifest}" --ignore-not-found=true 2>/dev/null || true
}

eda_api_url() {
  local lb_addr

  if [ -n "${EDA_URL:-}" ]; then
    echo "${EDA_URL%/}"
    return 0
  fi

  lb_addr=$(kubectl -n "${EDA_SYSTEM_NS}" get svc eda-api \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "${lb_addr}" ]; then
    echo "https://${lb_addr}"
    return 0
  fi

  return 1
}

eda_api_token() {
  local api_url=$1
  local client_secret username password

  command -v jq >/dev/null 2>&1 || return 1

  client_secret=$(kubectl -n "${EDA_SYSTEM_NS}" get secret eda-api-client-secret \
    -o jsonpath='{.data.clientKey}' 2>/dev/null | base64 -d)
  username=$(kubectl -n "${EDA_SYSTEM_NS}" get secret eda-realm-auth-secret \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
  password=$(kubectl -n "${EDA_SYSTEM_NS}" get secret eda-realm-auth-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  curl -k -s "${api_url}/core/httpproxy/v1/keycloak/realms/eda/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=eda-api-server" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "scope=openid" \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "client_secret=${client_secret}" | jq -r '.access_token // empty'
}

delete_eda_namespace_api() {
  local api_url token status response_file

  api_url=$(eda_api_url) || return 1
  token=$(eda_api_token "${api_url}")
  [ -n "${token}" ] || return 1

  response_file=$(mktemp)
  status=$(curl -k -s -X DELETE -o "${response_file}" -w "%{http_code}" \
    "${api_url}/apps/core.eda.nokia.com/v1/namespaces/${ST_STACK_NS}?detailLevel=standard&disableBatching=true" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json")

  if [[ "${status}" == "200" || "${status}" == "404" ]]; then
    rm -f "${response_file}"
    return 0
  fi

  echo "Warning: EDA API namespace delete returned HTTP ${status}: $(cat "${response_file}")" >&2
  rm -f "${response_file}"
  return 1
}

echo "Cleaning up EDA NetBox lab..."

echo "Stopping port-forwards..."
pkill -f "kubectl port-forward.*netbox" 2>/dev/null || true

echo "Deleting EDA namespace through EDA API..."
if have_edactl; then
  wait_for_eda_transactions 120 10 || true
  if eda_namespace_visible; then
    delete_eda_namespace_api || {
      echo "Warning: EDA API namespace delete failed; deleting residual EDA Namespace CR." >&2
      kubectl -n "${EDA_SYSTEM_NS}" delete namespace.core.eda.nokia.com "${ST_STACK_NS}" \
        --ignore-not-found=true --wait=true --timeout=300s 2>/dev/null || true
    }
    wait_for_eda_transactions 120 10 || true
    wait_for_eda_namespace_deleted 90 10 || true
  else
    echo "EDA namespace ${ST_STACK_NS} is not present."
  fi
else
  echo "Warning: edactl is unavailable; falling back to Kubernetes resource cleanup." >&2
fi

echo "Deleting residual EDA resources from Kubernetes API..."
delete_manifest_if_present manifests/0060_fabric.yaml
delete_manifest_if_present manifests/0020_allocations.yaml
delete_manifest_if_present manifests/0010_netbox_instance.yaml
delete_manifest_if_present manifests/0005_netbox_ui_httpproxy.yaml

echo "Deleting secrets..."
kubectl delete secret netbox-api-token -n "${ST_STACK_NS}" 2>/dev/null || true
kubectl delete secret netbox-webhook-signature -n "${ST_STACK_NS}" 2>/dev/null || true

echo "Uninstalling NetBox app..."
UNINSTALL_WF=$(kubectl create -f - 2>/dev/null <<YAML || true
apiVersion: appstore.eda.nokia.com/v1
kind: AppInstaller
metadata:
  generateName: netbox-uninstall-
  namespace: ${EDA_SYSTEM_NS}
spec:
  operation: delete
  apps:
    - appId: netbox.eda.nokia.com
      catalog: eda-catalog-builtin-apps
      version:
        type: semver
        value: ${NETBOX_APP_VERSION}
YAML
)
UNINSTALL_WF_NAME=$(echo "$UNINSTALL_WF" | awk '{print $1}')
if [ -n "${UNINSTALL_WF_NAME}" ]; then
  kubectl -n "${EDA_SYSTEM_NS}" wait --for=jsonpath='{.status.result}'=Completed \
    "$UNINSTALL_WF_NAME" --timeout=300s 2>/dev/null || true
fi

sleep 10

echo "Deleting residual Kubernetes namespace..."
kubectl delete namespace "${ST_STACK_NS}" \
  --ignore-not-found=true --wait=true --timeout=300s 2>/dev/null || true

echo "Uninstalling NetBox helm release..."
helm uninstall netbox-server -n "${NETBOX_NS}" 2>/dev/null || true

echo "Deleting NetBox namespace..."
kubectl delete namespace "${NETBOX_NS}" --wait=false 2>/dev/null || true

echo "Cleaning up local files..."
rm -f .netbox_url .eda_api_address

echo "Cleanup completed!"
