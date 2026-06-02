# config-generation-gitops

GitOps repository for the **Config Generation** platform.  
All Kubernetes infrastructure and application state is declared here and reconciled automatically by [ArgoCD](https://argo-cd.readthedocs.io/).

## Branches

| Branch | Target |
|--------|--------|
| `main` | Local deployment on a single-node [Kind](https://kind.sigs.k8s.io/) cluster |
| *(planned)* `aws` | AWS (EKS) |
| *(planned)* `gcp` | GCP (GKE) |

## Documentation

- [Local deployment operation guide](docs/operation-guide.md) — prerequisites, bootstrap steps, secrets setup, DNS/TLS, day-2 operations, and troubleshooting for the `main` branch.
- [GPC deployment operation guide](docs/GPC-guide.md) — prerequisites, bootstrap steps, secrets setup, DNS/TLS, day-2 operations, and troubleshooting for the `GPC` branch.
