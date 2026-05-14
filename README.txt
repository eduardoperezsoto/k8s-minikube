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
  b. Manual --> Run the setup script to create the full cluster (Gitea, Harbor, ArgoCD, runner):
    .devcontainer/setup-cluster.sh

2. Expose API
kubectl port-forward -n apisix svc/apisix-gateway 8080:80

Access via browser:
  Gitea:  http://gitea.127.0.0.1.nip.io:8080   user: admin  pass: admin123
  Harbor: http://registry.127.0.0.1.nip.io:8080 user: admin  pass: Harbor12345
  ArgoCD: http://argocd.127.0.0.1.nip.io:8080   user: admin  pass: (printed at end of setup script)

3. Configure Harbor
  a. Log in to Harbor at http://registry.127.0.0.1.nip.io:8080
  b. Create a new project: Projects → New Project → Name: myproject → Access level: Private

4. Configure Gitea repository
  a. Log in to Gitea at http://gitea.127.0.0.1.nip.io:8080
  b. Create a new repository for your application.
  c. Add the pipeline secrets under:
     Settings → Secrets and variables → Actions → New secret

     build-scan-push pipeline:
       HARBOR_URL      harbor.harbor.svc.cluster.local:80
       HARBOR_USER     admin
       HARBOR_PASS     Harbor12345
       HARBOR_PROJECT  myproject

     cleanup-images pipeline:
       ARGOCD_URL      http://argocd-server.argocd.svc.cluster.local
       ARGOCD_USER     admin
       ARGOCD_PASS     (kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
       HARBOR_URL      harbor.harbor.svc.cluster.local:80
       HARBOR_USER     admin
       HARBOR_PASS     Harbor12345

5. Configure ArgoCD application
  a. Log in to ArgoCD at http://argocd.127.0.0.1.nip.io:8080
  b. New App:
       Application Name:  app
       Project:           default
       Sync Policy:       Automatic
       Repository URL:    http://gitea-http.gitea.svc.cluster.local:3000/admin/<repo-name>  (internal URL, ArgoCD accesses Gitea from inside the cluster)
       Path:              k8s
       Cluster URL:       https://kubernetes.default.svc
       Namespace:         default
  c. Create → Sync

6. Sync pipelines and push app repo to Gitea
  a. Copy the pipelines into the app repo:
       scripts/sync-pipelines.sh /path/to/your/app/repo
  b. Commit and push to Gitea. The pipeline will trigger automatically.
