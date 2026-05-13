#!/bin/bash
set -e

echo "==> 1. Iniciando minikube..."
minikube delete --purge 2>/dev/null || true
minikube start --driver=docker --force

echo "==> 2. Añadiendo repos Helm..."
helm repo add gitea-charts   https://dl.gitea.com/charts/
helm repo add harbor         https://helm.goharbor.io
helm repo add argo           https://argoproj.github.io/argo-helm
helm repo add apisix         https://charts.apiseven.com
helm repo add jetstack       https://charts.jetstack.io
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo add external-dns   https://kubernetes-sigs.github.io/external-dns/
helm repo update

echo "==> 3. Instalando cert-manager..."
kubectl create namespace cert-manager 2>/dev/null || true
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
  -f /workspaces/minikube/k8s/cert-manager/values.yaml --wait --timeout 5m
kubectl wait --for=condition=available --timeout=3m -n cert-manager deployment/cert-manager-webhook
kubectl apply -f /workspaces/minikube/k8s/cert-manager/cluster-issuer.yaml

echo "==> 4. Instalando Sealed Secrets..."
kubectl create namespace sealed-secrets 2>/dev/null || true
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets -n sealed-secrets \
  -f /workspaces/minikube/k8s/sealed-secrets/values.yaml --wait --timeout 3m

echo "==> 5. Instalando APISIX..."
kubectl create namespace apisix 2>/dev/null || true
helm upgrade --install apisix apisix/apisix -n apisix \
  -f /workspaces/minikube/k8s/apisix/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/k8s/apisix/gateway-proxy.yaml
kubectl apply -f /workspaces/minikube/k8s/apisix/ingressclass.yaml

echo "==> 6. Instalando External-DNS (dry-run, no bloquea)..."
kubectl create namespace external-dns 2>/dev/null || true
helm upgrade --install external-dns external-dns/external-dns -n external-dns \
  -f /workspaces/minikube/k8s/external-dns/values.yaml --timeout 3m || \
  echo "    [WARN] External-DNS no está listo (requiere proveedor DNS real para funcionar)"

echo "==> 7. Instalando Gitea..."
kubectl create namespace gitea 2>/dev/null || true
helm upgrade --install gitea gitea-charts/gitea -n gitea \
  -f /workspaces/minikube/k8s/gitea/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/k8s/gitea/ingress.yaml

echo "==> 8. Instalando Harbor..."
kubectl create namespace harbor 2>/dev/null || true
helm upgrade --install harbor harbor/harbor -n harbor \
  -f /workspaces/minikube/k8s/harbor/values.yaml --wait --timeout 10m
kubectl apply -f /workspaces/minikube/k8s/harbor/ingress.yaml

echo "==> 9. Instalando ArgoCD..."
kubectl create namespace argocd 2>/dev/null || true
helm upgrade --install argocd argo/argo-cd -n argocd \
  -f /workspaces/minikube/k8s/argocd/values.yaml --wait --timeout 5m
kubectl apply -f /workspaces/minikube/k8s/argocd/ingress.yaml

echo ""
echo "============================================"
echo "Cluster listo. Para acceder desde tu PC ejecuta:"
echo "  kubectl port-forward -n apisix svc/apisix-gateway 8080:80"
echo ""
echo "  ArgoCD: http://argocd.127.0.0.1.nip.io:8080"
echo "  Gitea:  http://gitea.127.0.0.1.nip.io:8080"
echo "  Harbor: http://registry.127.0.0.1.nip.io:8080"
echo ""
echo "  Contraseña ArgoCD:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "============================================"
