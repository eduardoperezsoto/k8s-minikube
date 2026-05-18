#!/bin/bash
set -e

echo "==> 1. Iniciando minikube..."
minikube delete --purge 2>/dev/null || true
minikube start --driver=docker --force

echo "==> 2. Añadiendo repos Helm..."
helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo add harbor      https://helm.goharbor.io
helm repo add argo        https://argoproj.github.io/argo-helm
helm repo add apisix      https://charts.apiseven.com
helm repo update

echo "==> 3. Instalando APISIX..."
kubectl create namespace apisix 2>/dev/null || true
helm upgrade --install apisix apisix/apisix -n apisix \
  -f /workspaces/minikube/k8s/apisix/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/k8s/apisix/gateway-proxy.yaml
kubectl apply -f /workspaces/minikube/k8s/apisix/ingressclass.yaml


echo "==> 4. Instalando Gitea..."
kubectl create namespace gitea 2>/dev/null || true
helm upgrade --install gitea gitea-charts/gitea -n gitea \
  -f /workspaces/minikube/k8s/gitea/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/k8s/gitea/ingress.yaml

echo "==> 5. Instalando Harbor..."
kubectl create namespace harbor 2>/dev/null || true
helm upgrade --install harbor harbor/harbor -n harbor \
  -f /workspaces/minikube/k8s/harbor/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/k8s/harbor/ingress.yaml

kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=harbor.harbor.svc.cluster.local:80 \
  --docker-username=admin --docker-password=Harbor12345 \
  -n default --dry-run=client -o yaml | kubectl apply -f -

# Crear proyecto Harbor (idempotente — 409 si ya existe)
kubectl exec -n harbor deploy/harbor-core -- curl -s -o /dev/null \
  -w "  Crear proyecto Harbor 'ednel': HTTP %{http_code}\n" \
  -X POST \
  -H "Authorization: Basic $(echo -n 'admin:Harbor12345' | base64)" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"ednel","public":false}' \
  "http://localhost:8080/api/v2.0/projects" || true

echo "==> 6. Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd -n argocd \
  -f /workspaces/minikube/k8s/argocd/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/k8s/argocd/ingress.yaml

echo "==> 7. Publicando repos en Gitea (infra + app)..."
kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

# Crear repos
curl -s -o /dev/null -w "  Crear repo infra: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"infra","private":false,"auto_init":false}' \
  "http://localhost:3000/api/v1/user/repos" || true

curl -s -o /dev/null -w "  Crear repo app:   HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"app","private":false,"auto_init":false}' \
  "http://localhost:3000/api/v1/user/repos" || true

# Push k8s/ → repo infra (snapshot del estado actual, sin tocar el repo externo)
INFRA_TMP=$(mktemp -d)
cp -r /workspaces/minikube/k8s/. "${INFRA_TMP}/"
git -C "${INFRA_TMP}" init
git -C "${INFRA_TMP}" config user.email "setup@local"
git -C "${INFRA_TMP}" config user.name "Setup"
git -C "${INFRA_TMP}" add -A
git -C "${INFRA_TMP}" commit -m "infra snapshot"
git -C "${INFRA_TMP}" remote add gitea http://admin:admin123@localhost:3000/admin/infra.git
git -C "${INFRA_TMP}" push gitea HEAD:main --force
rm -rf "${INFRA_TMP}"

# Push app/
APP_TMP=$(mktemp -d)
cp -r /workspaces/minikube/app/. "${APP_TMP}/"
git -C "${APP_TMP}" init
git -C "${APP_TMP}" config user.email "setup@local"
git -C "${APP_TMP}" config user.name "Setup"
git -C "${APP_TMP}" add -A
git -C "${APP_TMP}" commit -m "app snapshot"
git -C "${APP_TMP}" remote add gitea http://admin:admin123@localhost:3000/admin/app.git
git -C "${APP_TMP}" push gitea HEAD:main --force
rm -rf "${APP_TMP}"

kill $PF_PID
wait $PF_PID 2>/dev/null || true

echo "==> 8. Instalando Tekton Pipelines, Triggers y Dashboard..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-pipelines-controller
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-pipelines-webhook
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-triggers-controller
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-triggers-webhook
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl wait --for=condition=available --timeout=3m \
  -n tekton-pipelines deployment/tekton-dashboard
kubectl -n tekton-pipelines get deployment tekton-dashboard -o json \
  | sed 's/--read-only=true/--read-only=false/' \
  | kubectl apply -f -

echo "==> 9. Registrando ArgoCD Applications..."
kubectl apply -f /workspaces/minikube/k8s/argocd/apps/

# Allow Harbor containers to push: the ClusterIP is within 10.96.0.0/12
HARBOR_IP=$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.clusterIP}')
minikube ssh -- "echo '${HARBOR_IP} harbor.harbor.svc.cluster.local' | sudo tee -a /etc/hosts"

echo "==> 10. Configurando webhook en Gitea..."
kubectl wait --for=condition=available --timeout=2m \
  -n ci deployment/el-gitea-listener 2>/dev/null || true

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

for REPO in $(curl -s \
  -H "${GITEA_AUTH}" \
  "http://localhost:3000/api/v1/repos/search?limit=50" \
  | jq -r '.data[].name' 2>/dev/null); do
  curl -s -o /dev/null -w "  Webhook → ${REPO}: %{http_code}\n" \
    -X POST \
    -H "${GITEA_AUTH}" \
    -H "Content-Type: application/json" \
    -d '{
      "type": "gitea",
      "active": true,
      "events": ["push"],
      "config": {
        "url": "http://el-gitea-listener.ci.svc.cluster.local:8080",
        "content_type": "json"
      }
    }' \
    "http://localhost:3000/api/v1/repos/admin/${REPO}/hooks"
done

kill $PF_PID
wait $PF_PID 2>/dev/null || true

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo "==> 11. Configurando secret de limpieza de imágenes..."
kubectl create namespace ci 2>/dev/null || true
kubectl create secret generic cleanup-credentials \
  --from-literal=argocd-url=http://argocd-server.argocd.svc.cluster.local \
  --from-literal=argocd-user=admin \
  --from-literal=argocd-pass="${ARGOCD_PASS}" \
  --from-literal=harbor-url=http://harbor.harbor.svc.cluster.local:80 \
  --from-literal=harbor-user=admin \
  --from-literal=harbor-pass=Harbor12345 \
  -n ci --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "============================================"
echo "Cluster listo. Para acceder desde tu PC ejecuta:"
echo "  kubectl port-forward -n apisix svc/apisix-gateway 8080:80"
echo ""
echo "  Gitea:  http://gitea.127.0.0.1.nip.io:8080"
echo "    user: admin"
echo "    pass: admin123"
echo ""
echo "  Harbor: http://registry.127.0.0.1.nip.io:8080"
echo "    user: admin"
echo "    pass: Harbor12345"
echo ""
echo "  ArgoCD: http://argocd.127.0.0.1.nip.io:8080"
echo "    user: admin"
echo "    pass: ${ARGOCD_PASS}"
echo ""
echo "  Tekton Dashboard: http://tekton.127.0.0.1.nip.io:8080"
echo "============================================"
