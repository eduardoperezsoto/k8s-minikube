#!/bin/bash
set -e

echo "==> 1. Iniciando minikube..."
minikube delete --purge 2>/dev/null || true
minikube start --driver=docker --force --insecure-registry="harbor.harbor.svc.cluster.local:80"

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

# Crear proyecto Harbor
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

kubectl create secret generic gitea-repo-creds \
  --from-literal=type=git \
  --from-literal=url=http://gitea-http.gitea.svc.cluster.local:3000 \
  --from-literal=username=admin \
  --from-literal=password=admin123 \
  -n argocd --dry-run=client -o yaml \
| kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
| kubectl apply -f -

echo "==> 7. Publicando repos en Gitea (infra + app)..."
kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

# Crear org ednel
curl -s -o /dev/null -w "  Crear org ednel: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"username":"ednel","visibility":"private"}' \
  "http://localhost:3000/api/v1/orgs" || true

# Crear repos bajo la org ednel
curl -s -o /dev/null -w "  Crear repo infra: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"infra","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/ednel/repos" || true

curl -s -o /dev/null -w "  Crear repo app:   HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"app","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/ednel/repos" || true

# Push k8s/ → repo infra
INFRA_TMP=$(mktemp -d)
cp -r /workspaces/minikube/k8s/. "${INFRA_TMP}/"
git -C "${INFRA_TMP}" init
git -C "${INFRA_TMP}" config user.email "setup@local"
git -C "${INFRA_TMP}" config user.name "Setup"
git -C "${INFRA_TMP}" add -A
git -C "${INFRA_TMP}" commit -m "infra snapshot"
git -C "${INFRA_TMP}" remote add gitea http://admin:admin123@localhost:3000/ednel/infra.git
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
git -C "${APP_TMP}" remote add gitea http://admin:admin123@localhost:3000/ednel/app.git
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

echo "==> 10. Construyendo imagen de cleanup en Harbor..."
eval $(minikube docker-env)
docker build -t harbor.harbor.svc.cluster.local:80/ednel/harbor-cleanup:latest \
  /workspaces/minikube/k8s/tekton/cleanup/
echo "Harbor12345" | docker login harbor.harbor.svc.cluster.local:80 \
  -u admin --password-stdin
docker push harbor.harbor.svc.cluster.local:80/ednel/harbor-cleanup:latest
eval $(minikube docker-env --unset)


echo "==> 11. Configurando webhook en Gitea..."
kubectl create namespace ci 2>/dev/null || true

kubectl wait --for=condition=available --timeout=2m \
  -n ci deployment/el-gitea-listener 2>/dev/null || true

WEBHOOK_SECRET=$(openssl rand -hex 32)
kubectl create secret generic gitea-webhook-secret \
  --from-literal=secret="${WEBHOOK_SECRET}" \
  -n ci --dry-run=client -o yaml | kubectl apply -f -

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

# Delete existing hooks on app to avoid duplicates on re-run
for HOOK_ID in $(curl -s -H "${GITEA_AUTH}" \
  "http://localhost:3000/api/v1/repos/ednel/app/hooks?limit=50" \
  | jq -r '.[].id' 2>/dev/null); do
  curl -s -o /dev/null \
    -X DELETE -H "${GITEA_AUTH}" \
    "http://localhost:3000/api/v1/repos/ednel/app/hooks/${HOOK_ID}"
done
curl -s -o /dev/null -w "  Webhook → app: %{http_code}\n" \
  -X POST \
  -H "${GITEA_AUTH}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg token "${WEBHOOK_SECRET}" \
    '{type:"gitea",active:true,events:["push"],authorization_header:$token,config:{url:"http://el-gitea-listener.ci.svc.cluster.local:8080",content_type:"json"}}')" \
  "http://localhost:3000/api/v1/repos/ednel/app/hooks"

kill $PF_PID
wait $PF_PID 2>/dev/null || true

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo "==> 12. Configurando secrets de CI..."
kubectl create secret generic gitea-credentials \
  --from-literal=.gitconfig="$(printf '[credential]\n    helper = store\n')" \
  --from-literal=.git-credentials="http://admin:admin123@gitea-http.gitea.svc.cluster.local:3000" \
  -n ci --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic argocd-credentials \
  --from-literal=argocd-url=http://argocd-server.argocd.svc.cluster.local \
  --from-literal=argocd-user=admin \
  --from-literal=argocd-pass="${ARGOCD_PASS}" \
  -n ci --dry-run=client -o yaml | kubectl apply -f -

HARBOR_AUTH=$(printf 'admin:Harbor12345' | base64 -w0)
HARBOR_CONFIG="{\"auths\":{\"harbor.harbor.svc.cluster.local:80\":{\"auth\":\"${HARBOR_AUTH}\"}}}"
kubectl create secret generic harbor-credentials \
  --from-literal=config.json="${HARBOR_CONFIG}" \
  --from-literal=harbor-url=http://harbor.harbor.svc.cluster.local:80 \
  --from-literal=harbor-user=admin \
  --from-literal=harbor-pass=Harbor12345 \
  -n ci --dry-run=client -o yaml \
| kubectl annotate --local -f - tekton.dev/docker-0=harbor.harbor.svc.cluster.local:80 -o yaml \
| kubectl apply -f -

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
