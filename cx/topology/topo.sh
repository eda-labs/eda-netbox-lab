#!/bin/bash

# Wrapper around api-server-topo to load or remove CX topologies.

CMD=${1}
TOPO_YAML=${2}
SIMTOPO_FILE=${3}
TOPO_NS=${TOPO_NS:-eda-netbox}
CORE_NS=${CORE_NS:-eda-system}

if [[ "${CMD}" == "remove" ]]; then
  echo "Removing topology from namespace ${TOPO_NS}"
  cat <<EOT | kubectl apply -n ${TOPO_NS} -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: eda-topology
data:
  eda.yaml: |
    {}
EOT

  echo "Removing sim topology from namespace ${TOPO_NS}"
  cat <<EOT | kubectl apply -n ${TOPO_NS} -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: eda-topology-sim
data:
  sim.yaml: |
    {}
EOT

  kubectl -n ${CORE_NS} exec \
    $(kubectl get -n ${CORE_NS} pods -l eda.nokia.com/app=eda-toolbox -o jsonpath="{.items[0].metadata.name}") \
    -- api-server-topo -n ${TOPO_NS}
  exit $?
fi

if [[ "${CMD}" == "load" ]]; then
  if [ -z "${TOPO_YAML}" ] || [ -z "${SIMTOPO_FILE}" ]; then
    echo "Usage: $0 load <topology.yaml> <simtopology.yaml>"
    exit 1
  fi
  if [ ! -f "${TOPO_YAML}" ] || [ ! -f "${SIMTOPO_FILE}" ]; then
    echo "Topology files not found"
    exit 1
  fi

  TOOLBOX_POD=$(kubectl -n ${CORE_NS} get pods \
    -l eda.nokia.com/app=eda-toolbox -o jsonpath="{.items[0].metadata.name}")

  if [ -z "${TOOLBOX_POD}" ]; then
    echo "Could not find eda-toolbox pod in namespace ${CORE_NS}"
    exit 1
  fi

  TOPO_FILENAME=$(basename -- "${TOPO_YAML}")
  SIMTOPO_FILENAME=$(basename -- "${SIMTOPO_FILE}")

  echo "Copying topology ${TOPO_YAML} to ${CORE_NS}/${TOOLBOX_POD}:/tmp/${TOPO_FILENAME}"
  kubectl -n ${CORE_NS} cp "${TOPO_YAML}" "${TOOLBOX_POD}:/tmp/${TOPO_FILENAME}" || {
    echo "kubectl cp failed"
    exit 1
  }

  echo "Copying sim topology ${SIMTOPO_FILE} to ${CORE_NS}/${TOOLBOX_POD}:/tmp/${SIMTOPO_FILENAME}"
  kubectl -n ${CORE_NS} cp "${SIMTOPO_FILE}" "${TOOLBOX_POD}:/tmp/${SIMTOPO_FILENAME}" || {
    echo "kubectl cp failed"
    exit 1
  }

  echo "Converting topology YAML to JSON"
  kubectl -n ${CORE_NS} exec "${TOOLBOX_POD}" -- sh -c "yq -o json '.' /tmp/${TOPO_FILENAME} > /tmp/topo.json"
  kubectl -n ${CORE_NS} exec "${TOOLBOX_POD}" -- sh -c "yq -o json '.' /tmp/${SIMTOPO_FILENAME} > /tmp/simtopo.json"
  echo "Loading topology into namespace ${TOPO_NS}"
  kubectl -n ${CORE_NS} exec "${TOOLBOX_POD}" -- api-server-topo -n ${TOPO_NS} -f /tmp/topo.json -s /tmp/simtopo.json
  exit $?
fi

echo "Unsupported command ${CMD}"
exit 1
