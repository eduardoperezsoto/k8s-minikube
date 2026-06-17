#!/usr/bin/env bash
# Runs on every devcontainer start/reopen (the cluster is already installed).
# Starts minikube and restores the node /etc/hosts entry that lets the
# container runtime resolve the in-cluster Harbor registry. minikube
# regenerates /etc/hosts on each start, so this must be reapplied every time
# or image pulls from harbor.harbor.svc.cluster.local fail with ErrImagePull.
set -euo pipefail

minikube start --driver=docker --force

HARBOR_IP=$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "${HARBOR_IP}" ]; then
  minikube ssh -- "grep -q harbor.harbor.svc.cluster.local /etc/hosts \
    || echo '${HARBOR_IP} harbor.harbor.svc.cluster.local' | sudo tee -a /etc/hosts"
  echo "==> node /etc/hosts: harbor.harbor.svc.cluster.local -> ${HARBOR_IP}"
else
  echo "WARN: harbor/harbor Service not found; skipped /etc/hosts entry" >&2
fi
