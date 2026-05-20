# ----------- Useful commands -----------
Minikube basic
minikube start
minikube stop
minikube delete
minikube service service_name

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d


# ----------- Guide -----------
1. Cluster setup
  a. Automatically --> Open devcontainer
  b. Manual --> Run the setup script to create the full cluster:
    .devcontainer/setup-cluster.sh

2. Expose API
kubectl port-forward -n apisix svc/apisix-gateway 8080:80

Access via browser:
  Gitea:   http://gitea.127.0.0.1.nip.io:8080   user: admin  pass: admin123
  Harbor:  http://registry.127.0.0.1.nip.io:8080 user: admin  pass: Harbor12345
  ArgoCD:  http://argocd.127.0.0.1.nip.io:8080   user: admin  pass: (printed at end of setup script)
  Tekton:  http://tekton.127.0.0.1.nip.io:8080

3. Configure Harbor
  a. Log in to Harbor at http://registry.127.0.0.1.nip.io:8080
  b. Create a new project: Projects → New Project → Name: ednel → Access level: Private

4. Configure Gitea
  a. Log in to Gitea at http://gitea.127.0.0.1.nip.io:8080
  b. Create a repository for each application.
  c. The Pipelines as Code webhook is registered automatically by setup-cluster.sh.
     Any push to main triggers the PipelineRun defined in .tekton/push.yaml of the
     app repo.

5. ArgoCD (configured automatically by setup-cluster.sh)
  - Watches: http://gitea-http.gitea.svc.cluster.local:3000/admin/infra.git  path: k8s/app
  - Syncs the app Deployment and Service to namespace: default
  - To deploy a new image version, update k8s/app/deployment.yaml and push infra repo to Gitea.

6. Tekton CI with Pipelines as Code (configured automatically by setup-cluster.sh)
  - Tasks live cluster-side in k8s/tekton/tasks/ (namespace: ci)
  - Per-app PipelineRun lives in <app-repo>/.tekton/push.yaml
  - Repository CR (k8s/tekton/pac/repository.yaml) maps the Gitea repo URL to namespace ci
  - To update Tasks: push to infra repo; ArgoCD syncs to namespace ci
  - To change CI logic for an app: edit .tekton/push.yaml in that app's repo

7. Cleanup CronJob
  - Runs daily at 02:00 UTC, keeps current + previous Harbor image per repo
  - Script: k8s/tekton/cleanup/cleanup_images.py
  - Tekton pipeline: k8s/tekton/pipelines/cleanup-images.yaml (not PaC-driven; triggered by CronJob)
