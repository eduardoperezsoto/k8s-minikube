#!/bin/bash
# Pushes ansible-playbooks/ to the Gitea ansible-playbooks repo. Each push triggers
# install-ca via PAC when the CA under files/ (or the playbook) changes.
set -e

ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible-playbooks" && pwd)"

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3
trap "kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null || true" EXIT

ANSIBLE_TMP=$(mktemp -d)
cp -r "${ANSIBLE_DIR}/." "${ANSIBLE_TMP}/"
git -C "${ANSIBLE_TMP}" init
git -C "${ANSIBLE_TMP}" config user.email "setup@local"
git -C "${ANSIBLE_TMP}" config user.name "Setup"
git -C "${ANSIBLE_TMP}" add -A
git -C "${ANSIBLE_TMP}" commit -m "ansible-playbooks snapshot"
git -C "${ANSIBLE_TMP}" remote add origin http://admin:admin@localhost:3000/cnie-c0-infra/ansible-playbooks.git
git -C "${ANSIBLE_TMP}" push origin HEAD:main --force
rm -rf "${ANSIBLE_TMP}"

echo "==> Pushed."
