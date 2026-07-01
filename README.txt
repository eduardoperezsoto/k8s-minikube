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
  Gitea:   http://gitea.127.0.0.1.nip.io:8080   user: admin  pass: admin
  Harbor:  http://registry.127.0.0.1.nip.io:8080 user: admin  pass: admin
  ArgoCD:  http://argocd.127.0.0.1.nip.io:8080   user: admin  pass: admin
  Tekton:  http://tekton.127.0.0.1.nip.io:8080

3. Configure Harbor
  a. Log in to Harbor at http://registry.127.0.0.1.nip.io:8080
  b. Create a new project: Projects → New Project → Name: c0-apps → Access level: Private

4. Configure Gitea
  a. Log in to Gitea at http://gitea.127.0.0.1.nip.io:8080
  b. Create a repository for each application.
  c. The Pipelines as Code webhook is registered automatically by setup-cluster.sh.
     Any push to main triggers the PipelineRun defined in .tekton/push.yaml of the
     app repo.

5. ArgoCD (configured automatically by setup-cluster.sh)
  - Watches Gitea repo cnie-c0-infra/infra (synced from infra/) — path: app
  - Syncs the app Deployment and Service to namespace: default
  - To deploy a new image version, update infra/app/deployment.yaml and run `make sync-infra`.

6. Tekton CI with Pipelines as Code (configured automatically by setup-cluster.sh)
  - Pipelines/Tasks live in the Gitea repo cnie-c0-infra/tekton-pac-pipelines (synced from tekton-pac-pipelines/)
  - The Tekton git resolver fetches them on demand via the git resolver config in infra/tekton/git-resolver-config.yaml
  - Per-app PipelineRun lives in <app-repo>/.tekton/push.yaml
  - Repository CR (infra/tekton/pac/repository.yaml) maps the Gitea repo URL to namespace ci
  - To change a Pipeline/Task: edit under tekton-pac-pipelines/ and run `make sync-pipelines`
  - To change CI logic for an app: edit .tekton/push.yaml in that app's repo

7. Cleanup CronJob
  - Runs daily at 02:00 UTC, keeps current + previous Harbor image per repo
  - Script: infra/tekton/cleanup/cleanup-images.py
  - Tekton pipeline: tekton-pac-pipelines/pipelines/cleanup-harbor-images.yaml (not PaC-driven; triggered by CronJob)
