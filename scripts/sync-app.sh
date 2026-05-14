#!/bin/bash
# Pushes app/ to the Gitea app repo.
# Requires: port-forward active (kubectl port-forward -n gitea svc/gitea-http 3000:3000)
set -e

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../app" && pwd)"

git -C "${APP_DIR}" remote set-url origin http://admin:admin123@localhost:3000/admin/app.git 2>/dev/null || \
  git -C "${APP_DIR}" remote add origin http://admin:admin123@localhost:3000/admin/app.git

git -C "${APP_DIR}" push origin main --force

echo "==> Pushed. Tekton will trigger automatically on push to main."
