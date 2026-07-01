.PHONY: help setup sync-infra sync-pipelines sync-tekton-cicd-tools sync-app sync-ansible-playbooks sync proxy status pipelines cleanup

SHELL := /bin/bash

help:
	@echo "Targets disponibles:"
	@echo "  setup           Destruye y recrea el cluster completo"
	@echo "  sync-infra      Push infra/ al repo infra de Gitea"
	@echo "  sync-pipelines  Push tekton-pac-pipelines/ al repo tekton-pac-pipelines de Gitea"
	@echo "  sync-tekton-cicd-tools   Push tekton-cicd-tools/ al repo tekton-cicd-tools de Gitea (dispara build de imagen)"
	@echo "  sync-app        Push app/ al repo app de Gitea"
	@echo "  sync-ansible-playbooks   Push ansible-playbooks/ al repo ansible-playbooks de Gitea (dispara install-ca al cambiar la CA)"
	@echo "  sync            Push infra, pipelines, tekton-cicd-tools, app y ansible-playbooks"
	@echo "  proxy           Expone el gateway APISIX en localhost:8080"
	@echo "  status          Estado de pods en todos los namespaces relevantes"
	@echo "  pipelines       Últimos 10 PipelineRuns"
	@echo "  cleanup         Dispara el pipeline de limpieza de imágenes manualmente"

setup:
	bash .devcontainer/setup-cluster.sh

sync-infra:
	bash scripts/sync-infra.sh

sync-pipelines:
	bash scripts/sync-pipelines.sh

sync-tekton-cicd-tools:
	bash scripts/sync-tekton-cicd-tools.sh

sync-app:
	bash scripts/sync-app.sh

sync-ansible-playbooks:
	bash scripts/sync-ansible-playbooks.sh

sync: sync-infra sync-pipelines sync-tekton-cicd-tools sync-app sync-ansible-playbooks

proxy:
	@echo "Accesos disponibles en http://*.127.0.0.1.nip.io:8080"
	kubectl port-forward -n apisix svc/apisix-gateway 8080:80

status:
	@echo "=== cnie-pipelines-as-code ==="
	@kubectl get pods -n cnie-pipelines-as-code 2>/dev/null || true
	@echo "=== gitea ==="
	@kubectl get pods -n gitea 2>/dev/null || true
	@echo "=== harbor ==="
	@kubectl get pods -n harbor 2>/dev/null || true
	@echo "=== argocd ==="
	@kubectl get pods -n argocd 2>/dev/null || true
	@echo "=== tekton-pipelines ==="
	@kubectl get pods -n tekton-pipelines 2>/dev/null || true

pipelines:
	kubectl get pipelineruns -n cnie-pipelines-as-code --sort-by=.metadata.creationTimestamp | tail -10

cleanup:
	kubectl create -f infra/tekton-pac-deployments/cleanup/cleanup-images-pipelinerun.yaml
