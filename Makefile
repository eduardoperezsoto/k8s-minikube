.PHONY: help setup sync-infra sync-app sync proxy status pipelines cleanup-now

SHELL := /bin/bash

help:
	@echo "Targets disponibles:"
	@echo "  setup         Destruye y recrea el cluster completo"
	@echo "  sync-infra    Push k8s/ al repo infra de Gitea"
	@echo "  sync-app      Push app/ al repo app de Gitea"
	@echo "  sync          Push infra y app"
	@echo "  proxy         Expone el gateway APISIX en localhost:8080"
	@echo "  status        Estado de pods en todos los namespaces relevantes"
	@echo "  pipelines     Últimos 10 PipelineRuns"
	@echo "  cleanup   Dispara el pipeline de limpieza de imágenes manualmente"
	@echo "  argocd-pass   Muestra la contraseña de admin de ArgoCD"

setup:
	bash .devcontainer/setup-cluster.sh

sync-infra:
	bash scripts/sync-infra.sh

sync-app:
	bash scripts/sync-app.sh

sync: sync-infra sync-app

proxy:
	@echo "Accesos disponibles en http://*.127.0.0.1.nip.io:8080"
	kubectl port-forward -n apisix svc/apisix-gateway 8080:80

status:
	@echo "=== ci ==="
	@kubectl get pods -n ci 2>/dev/null || true
	@echo "=== gitea ==="
	@kubectl get pods -n gitea 2>/dev/null || true
	@echo "=== harbor ==="
	@kubectl get pods -n harbor 2>/dev/null || true
	@echo "=== argocd ==="
	@kubectl get pods -n argocd 2>/dev/null || true
	@echo "=== tekton-pipelines ==="
	@kubectl get pods -n tekton-pipelines 2>/dev/null || true

pipelines:
	kubectl get pipelineruns -n ci --sort-by=.metadata.creationTimestamp | tail -10

argocd-pass:
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d && echo

cleanup:
	kubectl create -f - <<'EOF'
	apiVersion: tekton.dev/v1
	kind: PipelineRun
	metadata:
	  generateName: cleanup-images-manual-
	  namespace: ci
	spec:
	  pipelineRef:
	    name: cleanup-images
	  serviceAccountName: tekton-pipeline-sa
	EOF
