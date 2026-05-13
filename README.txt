1. Minikube basic
minikube start
minikube stop
minikube delete
minikube service service_name

2. Exponer API
kubectl port-forward -n apisix svc/apisix-gateway 8080:80