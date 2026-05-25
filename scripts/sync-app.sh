#!/bin/bash
# Pushes app/ to the Gitea app repo.
set -e

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

APP_TMP=$(mktemp -d)
cp -r "${APP_DIR}/." "${APP_TMP}/"
git -C "${APP_TMP}" init
git -C "${APP_TMP}" config user.email "setup@local"
git -C "${APP_TMP}" config user.name "Setup"
git -C "${APP_TMP}" add -A
git -C "${APP_TMP}" commit -m "app snapshot"
git -C "${APP_TMP}" remote add origin http://admin:admin123@localhost:3000/cnie-c0-apps/app.git
git -C "${APP_TMP}" push origin HEAD:main --force
rm -rf "${APP_TMP}"

echo "==> Pushed."
