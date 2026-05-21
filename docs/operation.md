# Operation

## argoCD

```
kubectl port-forward svc/argocd-server -n argocd 8080:443

~/config-generation-gitops$ pkill -f "port-forward.*grafana"; kubectl port-forward --address 0.0.0.0 svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &
[2] 115369

```