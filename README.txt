1. Minikube basic
minikube start
minikube stop
minikube delete
minikube service service_name

2. Expose API
kubectl port-forward -n apisix svc/apisix-gateway 8080:80

3. Configure Harbor
  a. Log in to Harbor at http://registry.127.0.0.1.nip.io:8080
  b. Create a new project (e.g. "myproject") or use the default "library" project.

4. Configure Gitea repository
  a. Log in to Gitea at http://gitea.127.0.0.1.nip.io:8080
  b. Create a new repository for your application.
  c. Add the pipeline secrets under:
     Settings → Secrets and variables → Actions → New secret

     Required secrets:
       REGISTRY_URL      harbor.harbor.svc.cluster.local:80
       REGISTRY_USER     admin
       REGISTRY_PASS     Harbor12345
       REGISTRY_PROJECT  myproject   (the Harbor project created in step 4)
