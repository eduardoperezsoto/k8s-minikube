1. Minikube basic
minikube start
minikube stop
minikube delete
minikube service service_name

2. Argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

3. Exponer API
kubectl port-forward -n apisix svc/apisix-gateway 8080:80
