#!/bin/bash
# Pushes k8s/ to the Gitea infra repo so ArgoCD picks up the changes.
# Requires: port-forward active (kubectl port-forward -n gitea svc/gitea-http 3000:3000)
set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INFRA_TMP=$(mktemp -d)
cp -r "${REPO_ROOT}/k8s/." "${INFRA_TMP}/"
git -C "${INFRA_TMP}" init
git -C "${INFRA_TMP}" config user.email "setup@local"
git -C "${INFRA_TMP}" config user.name "Setup"
git -C "${INFRA_TMP}" add -A
git -C "${INFRA_TMP}" commit -m "infra snapshot"
git -C "${INFRA_TMP}" remote add gitea http://admin:admin123@localhost:3000/admin/infra.git
git -C "${INFRA_TMP}" push gitea main --force
rm -rf "${INFRA_TMP}"

echo "==> Pushed. ArgoCD will sync tekton-ci and app automatically."
