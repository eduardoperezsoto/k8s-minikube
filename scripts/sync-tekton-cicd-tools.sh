#!/bin/bash
# Pushes tekton-cicd-tools/ to the Gitea tekton-cicd-tools repo (source of the image used by
# CI Tasks). Each push triggers build-scan-push via PAC, which publishes the
# image to Harbor.
set -e

TEKTON_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tekton-cicd-tools" && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

TEKTON_TOOLS_TMP=$(mktemp -d)
cp -r "${TEKTON_TOOLS_DIR}/." "${TEKTON_TOOLS_TMP}/"
git -C "${TEKTON_TOOLS_TMP}" init
git -C "${TEKTON_TOOLS_TMP}" config user.email "setup@local"
git -C "${TEKTON_TOOLS_TMP}" config user.name "Setup"
git -C "${TEKTON_TOOLS_TMP}" add -A
git -C "${TEKTON_TOOLS_TMP}" commit -m "tekton-cicd-tools snapshot"
git -C "${TEKTON_TOOLS_TMP}" remote add origin http://admin:admin123@localhost:3000/cnie-c0-infra/tekton-cicd-tools.git
git -C "${TEKTON_TOOLS_TMP}" push origin HEAD:main --force
rm -rf "${TEKTON_TOOLS_TMP}"

echo "==> Pushed."
