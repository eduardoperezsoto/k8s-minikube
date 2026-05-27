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
  -f /workspaces/minikube/infra/apisix/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/infra/apisix/gateway-proxy.yaml
kubectl apply -f /workspaces/minikube/infra/apisix/ingressclass.yaml


echo "==> 4. Instalando Gitea..."
kubectl create namespace gitea 2>/dev/null || true
helm upgrade --install gitea gitea-charts/gitea -n gitea \
  -f /workspaces/minikube/infra/gitea/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/infra/gitea/ingress.yaml

echo "==> 5. Instalando Harbor..."
kubectl create namespace harbor 2>/dev/null || true
helm upgrade --install harbor harbor/harbor -n harbor \
  -f /workspaces/minikube/infra/harbor/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/infra/harbor/ingress.yaml

kubectl create secret docker-registry harbor-pull-secret \
  --docker-server=harbor.harbor.svc.cluster.local:80 \
  --docker-username=admin --docker-password=Harbor12345 \
  -n default --dry-run=client -o yaml | kubectl apply -f -

# Crear proyectos Harbor
kubectl exec -n harbor deploy/harbor-core -- curl -s -o /dev/null \
  -w "  Crear proyecto Harbor 'cnie-c0-apps':  HTTP %{http_code}\n" \
  -X POST \
  -H "Authorization: Basic $(echo -n 'admin:Harbor12345' | base64)" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"cnie-c0-apps","public":false}' \
  "http://localhost:8080/api/v2.0/projects" || true

kubectl exec -n harbor deploy/harbor-core -- curl -s -o /dev/null \
  -w "  Crear proyecto Harbor 'cnie-c0-infra': HTTP %{http_code}\n" \
  -X POST \
  -H "Authorization: Basic $(echo -n 'admin:Harbor12345' | base64)" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"cnie-c0-infra","public":false}' \
  "http://localhost:8080/api/v2.0/projects" || true

echo "==> 6. Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd -n argocd \
  -f /workspaces/minikube/infra/argocd/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/infra/argocd/ingress.yaml

kubectl create secret generic gitea-repo-creds \
  --from-literal=type=git \
  --from-literal=url=http://gitea-http.gitea.svc.cluster.local:3000 \
  --from-literal=username=admin \
  --from-literal=password=admin123 \
  -n argocd --dry-run=client -o yaml \
| kubectl label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml \
| kubectl apply -f -

echo "==> 7. Publicando repos en Gitea (cnie-c0-infra/{infra,tekton-pac-pipelines,ci-utils} + cnie-c0-apps/app)..."
kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

# Crear orgs
curl -s -o /dev/null -w "  Crear org cnie-c0-infra: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"username":"cnie-c0-infra","visibility":"private"}' \
  "http://localhost:3000/api/v1/orgs" || true

curl -s -o /dev/null -w "  Crear org cnie-c0-apps:  HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"username":"cnie-c0-apps","visibility":"private"}' \
  "http://localhost:3000/api/v1/orgs" || true

# Crear repos infra y tekton-pac-pipelines bajo cnie-c0-infra
curl -s -o /dev/null -w "  Crear repo infra: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"infra","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/cnie-c0-infra/repos" || true

curl -s -o /dev/null -w "  Crear repo tekton-pac-pipelines: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"tekton-pac-pipelines","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/cnie-c0-infra/repos" || true

curl -s -o /dev/null -w "  Crear repo ci-utils: HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"ci-utils","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/cnie-c0-infra/repos" || true

# Crear repo app bajo cnie-c0-apps
curl -s -o /dev/null -w "  Crear repo app:   HTTP %{http_code}\n" \
  -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"app","private":true,"auto_init":false}' \
  "http://localhost:3000/api/v1/orgs/cnie-c0-apps/repos" || true

# Push infra/ → repo infra
INFRA_TMP=$(mktemp -d)
cp -r /workspaces/minikube/infra/. "${INFRA_TMP}/"
git -C "${INFRA_TMP}" init
git -C "${INFRA_TMP}" config user.email "setup@local"
git -C "${INFRA_TMP}" config user.name "Setup"
git -C "${INFRA_TMP}" add -A
git -C "${INFRA_TMP}" commit -m "infra snapshot"
git -C "${INFRA_TMP}" remote add gitea http://admin:admin123@localhost:3000/cnie-c0-infra/infra.git
git -C "${INFRA_TMP}" push gitea HEAD:main --force
rm -rf "${INFRA_TMP}"

# Push tekton-pac-pipelines/ → repo tekton-pac-pipelines
PIPELINES_TMP=$(mktemp -d)
cp -r /workspaces/minikube/tekton-pac-pipelines/. "${PIPELINES_TMP}/"
git -C "${PIPELINES_TMP}" init
git -C "${PIPELINES_TMP}" config user.email "setup@local"
git -C "${PIPELINES_TMP}" config user.name "Setup"
git -C "${PIPELINES_TMP}" add -A
git -C "${PIPELINES_TMP}" commit -m "pipelines snapshot"
git -C "${PIPELINES_TMP}" remote add gitea http://admin:admin123@localhost:3000/cnie-c0-infra/tekton-pac-pipelines.git
git -C "${PIPELINES_TMP}" push gitea HEAD:main --force
rm -rf "${PIPELINES_TMP}"

# Push ci-utils/ → repo ci-utils
CIUTILS_TMP=$(mktemp -d)
cp -r /workspaces/minikube/ci-utils/. "${CIUTILS_TMP}/"
git -C "${CIUTILS_TMP}" init
git -C "${CIUTILS_TMP}" config user.email "setup@local"
git -C "${CIUTILS_TMP}" config user.name "Setup"
git -C "${CIUTILS_TMP}" add -A
git -C "${CIUTILS_TMP}" commit -m "ci-utils snapshot"
git -C "${CIUTILS_TMP}" remote add gitea http://admin:admin123@localhost:3000/cnie-c0-infra/ci-utils.git
git -C "${CIUTILS_TMP}" push gitea HEAD:main --force
rm -rf "${CIUTILS_TMP}"

# Push app/
APP_TMP=$(mktemp -d)
cp -r /workspaces/minikube/app/. "${APP_TMP}/"
git -C "${APP_TMP}" init
git -C "${APP_TMP}" config user.email "setup@local"
git -C "${APP_TMP}" config user.name "Setup"
git -C "${APP_TMP}" add -A
git -C "${APP_TMP}" commit -m "app snapshot"
git -C "${APP_TMP}" remote add gitea http://admin:admin123@localhost:3000/cnie-c0-apps/app.git
git -C "${APP_TMP}" push gitea HEAD:main --force
rm -rf "${APP_TMP}"

kill $PF_PID
wait $PF_PID 2>/dev/null || true

echo "==> 8. Instalando Tekton Pipelines y Dashboard..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-pipelines-controller
kubectl wait --for=condition=available --timeout=5m \
  -n tekton-pipelines deployment/tekton-pipelines-webhook
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
kubectl wait --for=condition=available --timeout=3m \
  -n tekton-pipelines deployment/tekton-dashboard
kubectl -n tekton-pipelines get deployment tekton-dashboard -o json \
  | sed 's/--read-only=true/--read-only=false/' \
  | kubectl apply -f -
# The Dashboard release ships a ClusterRoleBinding for the (now removed)
# Tekton Triggers aggregate ClusterRole. Drop it to keep RBAC clean.
kubectl delete clusterrolebinding tekton-dashboard-triggers-view --ignore-not-found

echo "==> 8b. Instalando Pipelines as Code..."
kubectl apply -f https://raw.githubusercontent.com/openshift-pipelines/pipelines-as-code/stable/release.k8s.yaml
kubectl wait --for=condition=available --timeout=5m \
  -n pipelines-as-code deployment/pipelines-as-code-controller
kubectl wait --for=condition=available --timeout=5m \
  -n pipelines-as-code deployment/pipelines-as-code-webhook

# Point the commit-status "Details" link to the Tekton Dashboard ingress.
kubectl patch cm pipelines-as-code -n pipelines-as-code --type merge \
  -p '{"data":{"tekton-dashboard-url":"http://tekton.127.0.0.1.nip.io:8080"}}'
kubectl rollout restart -n pipelines-as-code deployment/pipelines-as-code-controller
kubectl rollout status -n pipelines-as-code deployment/pipelines-as-code-controller --timeout=60s

echo "==> 9. Registrando ArgoCD Applications..."
kubectl apply -f /workspaces/minikube/infra/argocd/apps/

# Allow Harbor containers to push: the ClusterIP is within 10.96.0.0/12
HARBOR_IP=$(kubectl get svc harbor -n harbor -o jsonpath='{.spec.clusterIP}')
minikube ssh -- "echo '${HARBOR_IP} harbor.harbor.svc.cluster.local' | sudo tee -a /etc/hosts"

echo "==> 11. Configurando Pipelines as Code + webhook en Gitea..."
kubectl create namespace ci 2>/dev/null || true

WEBHOOK_SECRET=$(openssl rand -hex 32)

kubectl port-forward -n gitea svc/gitea-http 3000:3000 &
PF_PID=$!
sleep 3

GITEA_AUTH="Authorization: Basic $(echo -n 'admin:admin123' | base64)"

# Rotate the Gitea PAT used by PaC to call back into Gitea (commit status, etc.).
# Gitea rejects duplicate token names, so delete any previous one first.
curl -s -H "${GITEA_AUTH}" \
  "http://localhost:3000/api/v1/users/admin/tokens" \
  | jq -r '.[] | select(.name=="pac") | .id' 2>/dev/null \
  | while read -r TOKEN_ID; do
      curl -s -o /dev/null -X DELETE -H "${GITEA_AUTH}" \
        "http://localhost:3000/api/v1/users/admin/tokens/${TOKEN_ID}"
    done

PAC_TOKEN=$(curl -s -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"pac","scopes":["write:repository","read:user","read:organization"]}' \
  "http://localhost:3000/api/v1/users/admin/tokens" \
  | jq -r '.sha1')

kubectl create secret generic gitea-pac-token \
  --from-literal=token="${PAC_TOKEN}" \
  -n tekton-ci --dry-run=client -o yaml | kubectl apply -f -

# Token consumed by the Tekton git resolver to fetch Pipelines/Tasks from the
# tekton-pac-pipelines repo via Gitea's SCM API. Read-only is enough.
curl -s -H "${GITEA_AUTH}" \
  "http://localhost:3000/api/v1/users/admin/tokens" \
  | jq -r '.[] | select(.name=="tekton-resolver") | .id' 2>/dev/null \
  | while read -r TOKEN_ID; do
      curl -s -o /dev/null -X DELETE -H "${GITEA_AUTH}" \
        "http://localhost:3000/api/v1/users/admin/tokens/${TOKEN_ID}"
    done

RESOLVER_TOKEN=$(curl -s -X POST -H "${GITEA_AUTH}" -H "Content-Type: application/json" \
  -d '{"name":"tekton-resolver","scopes":["read:repository"]}' \
  "http://localhost:3000/api/v1/users/admin/tokens" \
  | jq -r '.sha1')

kubectl create secret generic gitea-resolver-token \
  --from-literal=token="${RESOLVER_TOKEN}" \
  -n tekton-pipelines-resolvers --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitea-pac-webhook \
  --from-literal=webhook-secret="${WEBHOOK_SECRET}" \
  -n tekton-ci --dry-run=client -o yaml | kubectl apply -f -

# Register org-level webhook → in-cluster PaC controller. One hook per org
# fires for every repo in that org; PaC ignores events from repos without a
# matching Repository CR. Gitea signs the payload with the shared secret;
# PaC verifies it using the gitea-pac-webhook Secret.
register_pac_org_webhook() {
  local org="$1"
  for HOOK_ID in $(curl -s -H "${GITEA_AUTH}" \
    "http://localhost:3000/api/v1/orgs/${org}/hooks?limit=50" \
    | jq -r '.[].id' 2>/dev/null); do
    curl -s -o /dev/null \
      -X DELETE -H "${GITEA_AUTH}" \
      "http://localhost:3000/api/v1/orgs/${org}/hooks/${HOOK_ID}"
  done

  curl -s -o /dev/null -w "  Webhook → org/${org}: %{http_code}\n" \
    -X POST \
    -H "${GITEA_AUTH}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg secret "${WEBHOOK_SECRET}" \
      '{type:"gitea",active:true,events:["push","pull_request"],config:{url:"http://pipelines-as-code-controller.pipelines-as-code.svc.cluster.local:8080",content_type:"json",secret:$secret}}')" \
    "http://localhost:3000/api/v1/orgs/${org}/hooks"
}

register_pac_org_webhook "cnie-c0-apps"
register_pac_org_webhook "cnie-c0-infra"

kill $PF_PID
wait $PF_PID 2>/dev/null || true

ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)

echo "==> 12. Configurando secrets de CI..."
kubectl create secret generic gitea-creds \
  --from-literal=username=admin \
  --from-literal=password=admin123 \
  -n tekton-ci --dry-run=client -o yaml \
| sed '/^kind: Secret$/a type: kubernetes.io/basic-auth' \
| kubectl annotate --local -f - tekton.dev/git-0=http://gitea-http.gitea.svc.cluster.local:3000 -o yaml \
| kubectl apply -f -

kubectl create secret generic argocd-creds \
  --from-literal=url=http://argocd-server.argocd.svc.cluster.local \
  --from-literal=username=admin \
  --from-literal=password="${ARGOCD_PASS}" \
  -n tekton-ci --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry harbor-dockerconfig \
  --docker-server=harbor.harbor.svc.cluster.local:80 \
  --docker-username=admin \
  --docker-password=Harbor12345 \
  -n tekton-ci --dry-run=client -o yaml \
| kubectl annotate --local -f - tekton.dev/docker-0=harbor.harbor.svc.cluster.local:80 -o yaml \
| kubectl apply -f -

kubectl create secret generic harbor-creds \
  --from-literal=url=http://harbor.harbor.svc.cluster.local:80 \
  --from-literal=username=admin \
  --from-literal=password=Harbor12345 \
  -n tekton-ci --dry-run=client -o yaml | kubectl apply -f -

echo "==> 13. Disparando los primeros builds (re-push de ci-utils y app)..."
kubectl wait --for=condition=established --timeout=60s \
  crd/repositories.pipelinesascode.tekton.dev 2>/dev/null || true
for i in $(seq 1 12); do
  kubectl get repository ci-utils -n tekton-ci >/dev/null 2>&1 \
    && kubectl get repository app -n tekton-ci >/dev/null 2>&1 \
    && break
  sleep 5
done
# ci-utils primero: la Task cleanup-images depende de su imagen en Harbor.
bash /workspaces/minikube/scripts/sync-ci-utils.sh
bash /workspaces/minikube/scripts/sync-app.sh

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
