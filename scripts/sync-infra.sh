#!/bin/bash
# Pushes k8s/ to the Gitea infra repo (ArgoCD source of truth for all cluster config).
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

INFRA_TMP=$(mktemp -d)
cp -r "${REPO_ROOT}/k8s/." "${INFRA_TMP}/"
git -C "${INFRA_TMP}" init
git -C "${INFRA_TMP}" config user.email "setup@local"
git -C "${INFRA_TMP}" config user.name "Setup"
git -C "${INFRA_TMP}" add -A
git -C "${INFRA_TMP}" commit -m "infra snapshot"
git -C "${INFRA_TMP}" remote add gitea http://admin:admin123@localhost:3000/admin/infra.git
git -C "${INFRA_TMP}" push gitea HEAD:main --force
rm -rf "${INFRA_TMP}"

echo "==> Pushed."
