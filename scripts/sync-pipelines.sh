#!/bin/bash
# Pushes tekton-pac-pipelines/ to the Gitea tekton-pac-pipelines repo
# (source of truth for Pipeline/Task definitions fetched by the Tekton git resolver).
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

PIPELINES_TMP=$(mktemp -d)
cp -r "${REPO_ROOT}/tekton-pac-pipelines/." "${PIPELINES_TMP}/"
git -C "${PIPELINES_TMP}" init
git -C "${PIPELINES_TMP}" config user.email "setup@local"
git -C "${PIPELINES_TMP}" config user.name "Setup"
git -C "${PIPELINES_TMP}" add -A
git -C "${PIPELINES_TMP}" commit -m "pipelines snapshot"
git -C "${PIPELINES_TMP}" remote add gitea http://admin:admin@localhost:3000/cnie-c0-infra/tekton-pac-pipelines.git
git -C "${PIPELINES_TMP}" push gitea HEAD:main --force
rm -rf "${PIPELINES_TMP}"

echo "==> Pushed."
