#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS_SRC="$(cd "${SCRIPT_DIR}/../../.gitea/workflows" && pwd)"
TARGET_REPO="${1:-/workspaces/minikube/git-repos/app}"
TARGET_WORKFLOWS="${TARGET_REPO}/.gitea/workflows"

if [ ! -d "${TARGET_REPO}" ]; then
  echo "ERROR: repo not found: ${TARGET_REPO}"
  exit 1
fi

mkdir -p "${TARGET_WORKFLOWS}"
cp -r "${WORKFLOWS_SRC}/." "${TARGET_WORKFLOWS}/"

echo "Pipelines synced to ${TARGET_REPO}"
