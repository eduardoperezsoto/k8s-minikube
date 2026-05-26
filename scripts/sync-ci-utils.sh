#!/bin/bash
# Pushes ci-utils/ to the Gitea ci-utils repo (source of the image used by
# CI Tasks). Each push triggers build-scan-push via PAC, which publishes the
# image to Harbor.
set -e

CIUTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci-utils" && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

CIUTILS_TMP=$(mktemp -d)
cp -r "${CIUTILS_DIR}/." "${CIUTILS_TMP}/"
git -C "${CIUTILS_TMP}" init
git -C "${CIUTILS_TMP}" config user.email "setup@local"
git -C "${CIUTILS_TMP}" config user.name "Setup"
git -C "${CIUTILS_TMP}" add -A
git -C "${CIUTILS_TMP}" commit -m "ci-utils snapshot"
git -C "${CIUTILS_TMP}" remote add origin http://admin:admin123@localhost:3000/cnie-c0-infra/ci-utils.git
git -C "${CIUTILS_TMP}" push origin HEAD:main --force
rm -rf "${CIUTILS_TMP}"

echo "==> Pushed."
