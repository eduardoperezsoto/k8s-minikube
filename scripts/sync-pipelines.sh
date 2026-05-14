#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITEA_SRC="$(cd "${SCRIPT_DIR}/../.gitea" && pwd)"
TARGET_REPO="${1:-/workspaces/minikube/git-repos/app}"
TARGET_GITEA="${TARGET_REPO}/.gitea"

if [ ! -d "${TARGET_REPO}" ]; then
  echo "ERROR: repo not found: ${TARGET_REPO}"
  exit 1
fi

mkdir -p "${TARGET_GITEA}"
cp -r "${GITEA_SRC}/." "${TARGET_GITEA}/"

echo "Pipelines synced to ${TARGET_REPO}"
