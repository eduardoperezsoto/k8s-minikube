#!/bin/bash
set -e

echo "==> Installing Gitea Act Runner..."

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

RUNNER_TOKEN=$(curl -s \
  -H "Authorization: Basic $(echo -n 'admin:admin123' | base64)" \
  "http://localhost:3000/api/v1/admin/runners/registration-token" | jq -r '.token')

kill $PF_PID
wait $PF_PID 2>/dev/null || true

kubectl create secret generic act-runner-token \
  --from-literal=token="${RUNNER_TOKEN}" \
  -n gitea --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f /workspaces/minikube/k8s/gitea-runner/deployment.yaml
kubectl rollout status deployment/act-runner -n gitea --timeout=3m

# Allow job containers to push to Harbor: the Docker daemon on the minikube node
# resolves the hostname via /etc/hosts; the ClusterIP falls within 10.96.0.0/12
# which minikube already marks as insecure-registry, so no daemon restart is needed.
HARBOR_IP=$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.clusterIP}')
minikube ssh -- "echo '${HARBOR_IP} harbor.harbor.svc.cluster.local' | sudo tee -a /etc/hosts"

echo "==> Gitea Act Runner ready"
