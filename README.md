# config-generation-gitops

GitOps repository for the **Config Generation** platform.  
All Kubernetes infrastructure and application state is declared here.  
[ArgoCD](https://argo-cd.readthedocs.io/) watches this repo and automatically reconciles the cluster.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Bootstrap (one-time setup)](#bootstrap-one-time-setup)
   - [Phase 0 — Kind cluster](#phase-0--kind-cluster)
   - [Phase 1 — Install ArgoCD](#phase-1--install-argocd)
   - [Phase 2 — Hand off to GitOps](#phase-2--hand-off-to-gitops)
   - [Phase 3 — Create out-of-band secrets](#phase-3--create-out-of-band-secrets)
5. [DNS & TLS Setup](#dns--tls-setup)
6. [Deployed Services](#deployed-services)
7. [Day-2 Operations](#day-2-operations)
8. [CD Pipeline (image updates)](#cd-pipeline-image-updates)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet
  │  HTTPS (443)
  ▼
ingress-nginx  (Kind hostPort → host:443)
  ├── app.ycantech.com      → config-gen  (production namespace)
  ├── staging.ycantech.com  → config-gen  (config-gen-staging namespace)
  └── auth.ycantech.com     → Dex OIDC IdP (dex namespace)

config-gen backend
  ├── PostgreSQL via CloudNativePG + PgBouncer
  ├── Secrets from Infisical (secrets-operator)
  └── OIDC login via Dex → GitHub OAuth

cert-manager  →  Let's Encrypt (DNS-01 / Cloudflare API token)
ArgoCD        →  watches this repo (main branch), syncs all apps
```

**Sync waves** ensure correct ordering:

| Wave | What syncs |
|------|-----------|
| `-2` | CoreDNS (hairpin DNS rewrites) |
| `-1` | Infrastructure: ingress-nginx, cert-manager, CloudNativePG, Dex, Infisical, Reloader, kube-prometheus-stack |
| `1`  | Applications: config-gen-staging, config-gen-production |

---

## Repository Structure

```
├── kind-cluster.yaml              # Kind cluster config (hostPort 80/443)
├── apps/
│   ├── app-of-apps.yaml           # Root ArgoCD Application (bootstrapped manually)
│   ├── infrastructure/            # ArgoCD Applications for infra components
│   │   ├── cert-manager.yaml
│   │   ├── cloudnativepg.yaml
│   │   ├── coredns.yaml
│   │   ├── dex.yaml
│   │   ├── infisical.yaml
│   │   ├── ingress-nginx.yaml
│   │   ├── kube-prometheus-stack.yaml
│   │   └── reloader.yaml
│   ├── staging/
│   │   └── config-gen.yaml        # ArgoCD Application for staging
│   └── production/
│       └── config-gen.yaml        # ArgoCD Application for production
├── charts/
│   └── config-gen/                # Helm chart for the application
│       ├── values.yaml            # Base values (shared)
│       ├── values-staging.yaml    # Staging overrides (image tag updated by CI)
│       └── values-production.yaml # Production overrides (image tag updated by CI)
└── infrastructure/
    ├── argocd/values.yaml
    ├── cert-manager/
    │   ├── values.yaml
    │   └── issuers/               # ClusterIssuer manifests (letsencrypt-prod, selfsigned, etc.)
    ├── cloudnativepg/values.yaml
    ├── coredns/configmap.yaml     # Hairpin DNS rewrites for in-cluster hostname resolution
    ├── dex/values.yaml
    ├── infisical/values.yaml
    ├── ingress-nginx/values.yaml
    ├── kube-prometheus-stack/values.yaml
    └── reloader/values.yaml
```

---

## Prerequisites

| Tool | Version used | Install |
|------|-------------|---------|
| [kind](https://kind.sigs.k8s.io/) | v0.26+ | `brew install kind` or [release page](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.32+ | `brew install kubectl` |
| [Helm](https://helm.sh/) | v3.17+ | `brew install helm` |
| A public domain | — | Pointed at your server's IP via Cloudflare DNS |
| A Cloudflare account | — | For DNS-01 TLS cert issuance |
| A GitHub OAuth App | — | For user login via Dex |

**Ports 80 and 443 on the host machine must be reachable from the internet** for Let's Encrypt to issue certificates via the Cloudflare DNS-01 solver (no inbound port requirement for DNS-01, but the cluster must be able to reach the Cloudflare API).

---

## Bootstrap (one-time setup)

### Phase 0 — Kind cluster

```bash
kind create cluster --name config-gen --config kind-cluster.yaml
```

This creates a single-node cluster with host ports 80 and 443 mapped into the cluster for ingress-nginx.

---

### Phase 1 — Install ArgoCD

ArgoCD itself is bootstrapped manually with Helm. After this, ArgoCD manages its own upgrades.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f infrastructure/argocd/values.yaml
```

Wait until ArgoCD is ready (~2 min):

```bash
kubectl -n argocd wait deploy/argocd-server --for=condition=available --timeout=120s
```

---

### Phase 2 — Hand off to GitOps

Apply the App-of-Apps. From this point ArgoCD drives all further changes:

```bash
kubectl apply -f apps/app-of-apps.yaml
```

ArgoCD will recurse through `apps/` and create all child Applications.  
Watch progress:

```bash
kubectl -n argocd get applications -w
# or open the ArgoCD UI:
kubectl port-forward svc/argocd-server -n argocd 8080:443
# visit https://localhost:8080 (admin password below)
```

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

### Phase 3 — Create out-of-band secrets

These secrets are **never stored in git**. Create them once before ArgoCD-managed pods can start.

#### 3a. cert-manager — Cloudflare API token

Required for DNS-01 TLS certificate issuance.

1. In the Cloudflare dashboard, create an API token with **Zone / DNS / Edit** permission for your domain zone.
2. Apply it:

```bash
kubectl create namespace cert-manager   # may already exist after ArgoCD sync
kubectl create secret generic cloudflare-api-token-secret \
  -n cert-manager \
  --from-literal=api-token='<your-cloudflare-api-token>'
```

#### 3b. Dex — GitHub OAuth + OIDC client secrets

1. Create a [GitHub OAuth App](https://github.com/settings/developers):
   - Homepage URL: `https://auth.ycantech.com`
   - Authorization callback URL: `https://auth.ycantech.com/callback`
2. Generate two random secrets for the OIDC clients (one per environment):

```bash
STAGING_SECRET=$(openssl rand -hex 32)
PROD_SECRET=$(openssl rand -hex 32)
echo "Staging: $STAGING_SECRET"
echo "Production: $PROD_SECRET"
```

3. Create the Dex secret:

```bash
kubectl create namespace dex   # may already exist
kubectl create secret generic dex-secrets -n dex \
  --from-literal=GITHUB_CLIENT_SECRET='<github-oauth-app-client-secret>' \
  --from-literal=STAGING_CLIENT_SECRET="$STAGING_SECRET" \
  --from-literal=PRODUCTION_CLIENT_SECRET="$PROD_SECRET"
```

#### 3c. config-gen — OIDC client secret (per namespace)

The value must match the corresponding `*_CLIENT_SECRET` you set above.

```bash
# Staging
kubectl create namespace config-gen-staging   # may already exist
kubectl create secret generic config-gen-oidc-secret -n config-gen-staging \
  --from-literal=OIDC_CLIENT_SECRET="$STAGING_SECRET"

# Production
kubectl create namespace config-gen   # may already exist
kubectl create secret generic config-gen-oidc-secret -n config-gen \
  --from-literal=OIDC_CLIENT_SECRET="$PROD_SECRET"
```

#### 3d. config-gen — Application secrets (database URL, JWT secret, etc.)

Application secrets are managed by [Infisical](https://infisical.com/).

1. Create a project in Infisical and store the following secrets (see `infrastructure/infisical/values.yaml` for the full list):
   - `DATABASE_URL` — PgBouncer connection string
   - `DATABASE_DIRECT_URL` — direct CloudNativePG primary connection string (used by migrations)
   - `JWT_SECRET` — random 32+ byte string
   - `ADMIN_USERNAME` / `ADMIN_PASSWORD` — initial admin credentials
2. Create a Machine Identity with read access. Note the `clientId` and `clientSecret`.
3. Create the Infisical auth secret in each namespace:

```bash
for NS in config-gen-staging config-gen; do
  kubectl create secret generic infisical-auth -n $NS \
    --from-literal=clientId='<machine-identity-client-id>' \
    --from-literal=clientSecret='<machine-identity-client-secret>'
done
```

4. Edit `charts/config-gen/values-staging.yaml` and `values-production.yaml` — set `infisical.enabled: true` and fill in `infisical.authentication.universalAuth.secretsScope.projectSlug`.

---

## DNS & TLS Setup

1. In Cloudflare, create DNS **A records** for your domain pointing to your server's public IP:

   | Name | Type | Value |
   |------|------|-------|
   | `app` | A | `<server-ip>` |
   | `staging` | A | `<server-ip>` |
   | `auth` | A | `<server-ip>` |

2. Once the Cloudflare API token secret is in place and cert-manager is synced, certificates are issued automatically. Verify:

```bash
kubectl get certificates -A
# All should show READY=True within ~2 minutes
```

If a certificate is stuck, check:

```bash
kubectl describe certificaterequest -A | grep -A5 "Message:"
kubectl get challenges -A
# Restart cert-manager if challenges appear stuck after the token/config is correct:
kubectl rollout restart deployment -n cert-manager cert-manager cert-manager-webhook cert-manager-cainjector
```

---

## Deployed Services

| Service | Namespace | URL |
|---------|-----------|-----|
| Config Generation (production) | `config-gen` | https://app.ycantech.com |
| Config Generation (staging) | `config-gen-staging` | https://staging.ycantech.com |
| Dex OIDC | `dex` | https://auth.ycantech.com |
| ArgoCD | `argocd` | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| Prometheus / Grafana | `monitoring` | `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80` |

Login is via **GitHub OAuth** (email domain restricted to `nycu.edu.tw` by default; change `oidc.allowedEmailDomains` in the values files).

---

## Day-2 Operations

### Change configuration

Edit the relevant `values.yaml` (or `values-staging.yaml` / `values-production.yaml`), commit, and push to `main`. ArgoCD detects the change and self-heals automatically.

### Add a new public hostname (in-cluster DNS)

Backend pods resolve public hostnames via CoreDNS rewrites (to avoid hairpin NAT issues). If you add a new public hostname, add a line in `infrastructure/coredns/configmap.yaml`:

```yaml
rewrite name my-new-host.ycantech.com ingress-nginx-controller.ingress-nginx.svc.cluster.local
```

### Rotate the Cloudflare API token

```bash
kubectl create secret generic cloudflare-api-token-secret \
  -n cert-manager \
  --from-literal=api-token='<new-token>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment -n cert-manager cert-manager cert-manager-webhook cert-manager-cainjector
```

---

## CD Pipeline (image updates)

The application source lives in [config-generation](https://github.com/solar224/config-generation).  
The GitHub Actions CD workflow there:

1. Builds and pushes Docker images to `ghcr.io/brian030128/config-generation/{backend,frontend}`.
2. Opens a pull request in **this** repo updating the `image.backend.tag` / `image.frontend.tag` fields in `values-staging.yaml` (automatic merge) and `values-production.yaml` (requires human approval).
3. ArgoCD detects the merged change and deploys.

A PreSync hook runs database migrations (via `golang-migrate`) using `DATABASE_DIRECT_URL` before the new Deployment rolls out.

---

## Troubleshooting

### Pods not starting

```bash
kubectl get pods -A
kubectl describe pod -n <namespace> <pod-name>
kubectl logs -n <namespace> <pod-name>
```

### ArgoCD app stuck OutOfSync / Degraded

```bash
kubectl get applications -n argocd
kubectl describe application -n argocd <app-name>
```

Force a hard refresh:

```bash
kubectl annotate application -n argocd <app-name> argocd.argoproj.io/refresh=hard
```

### Certificate not issuing

```bash
kubectl get certificates,certificaterequests,challenges -A
kubectl describe challenge -n <namespace> <name>
```

Common causes: Cloudflare token missing or wrong permissions, cert-manager pods cached a failed state (restart them), DNS record not yet propagated.

### User login fails with `failed to provision user`

The user identity in the database stores the OIDC issuer URL. If the issuer URL changed (e.g., domain migration), update existing records:

```bash
kubectl exec -n config-gen config-gen-db-2 -- psql -U postgres -d config_gen \
  -c "UPDATE user_identities SET issuer='https://auth.ycantech.com' WHERE issuer='https://old-issuer.example.com';"
```

### CoreDNS not resolving internal hostnames

```bash
kubectl exec -n default <any-pod> -- nslookup auth.ycantech.com
# Should resolve to the ingress-nginx ClusterIP, not the public IP

# Reload CoreDNS after ConfigMap changes:
kubectl rollout restart deployment -n kube-system coredns
```
