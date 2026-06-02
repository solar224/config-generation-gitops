# Operation Guide — GCP Deployment (GKE)

This guide covers bootstrapping and operating the Config Generation platform on a Google Kubernetes Engine (GKE) cluster using the `GCP` branch of this repository.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [Prerequisites](#prerequisites)
4. [Bootstrap (one-time setup)](#bootstrap-one-time-setup)
   - [Phase 0 — GKE Cluster](#phase-0--gke-cluster)
   - [Phase 1 — Connect kubectl](#phase-1--connect-kubectl)
   - [Phase 2 — Install ArgoCD](#phase-2--install-argocd)
   - [Phase 3 — Hand off to GitOps](#phase-3--hand-off-to-gitops)
   - [Phase 4 — Create out-of-band secrets](#phase-4--create-out-of-band-secrets)
5. [DNS & TLS Setup](#dns--tls-setup)
6. [GCS Database Backup (Workload Identity)](#gcs-database-backup-workload-identity)
7. [Deployed Services](#deployed-services)
8. [High Availability Design](#high-availability-design)
9. [Day-2 Operations](#day-2-operations)
10. [CD Pipeline (image updates)](#cd-pipeline-image-updates)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet
  │  HTTPS (443)
  ▼
GCP External TCP Load Balancer  (auto-provisioned by GKE)
  ▼
ingress-nginx  ×2 pods  (type: LoadBalancer, externalTrafficPolicy: Local)
  ├── app.ycantech.com      → config-gen         (production namespace)
  ├── staging.ycantech.com  → config-gen-staging  (config-gen-staging namespace)
  └── auth.ycantech.com     → Dex OIDC IdP        (dex namespace)

config-gen backend  ×2 pods  (HPA min 2, max 4)
  ├── PostgreSQL via CloudNativePG (primary + hot-standby) + PgBouncer ×2
  ├── Secrets synced from Infisical (secrets-operator) → Reloader rolling restart
  └── OIDC login via Dex → GitHub OAuth

cert-manager  →  Let's Encrypt (DNS-01 / Cloudflare API token)
ArgoCD        →  watches this repo (GCP branch), syncs all apps
```

**Sync waves** ensure correct ordering:

| Wave | What syncs |
|------|-----------|
| `-2` | CoreDNS (GKE: no-op, ignored to preserve GKE-managed config) |
| `-1` | Infrastructure: ingress-nginx, cert-manager, CloudNativePG, Dex, Infisical, Reloader, kube-prometheus-stack |
| `1`  | Applications: config-gen-production, config-gen-staging |

---

## Repository Structure

```
├── apps/
│   ├── app-of-apps.yaml           # Root ArgoCD Application (bootstrapped manually)
│   ├── infrastructure/            # ArgoCD Applications for infra components
│   └── production/ & staging/     # ArgoCD Applications for config-gen
├── charts/
│   └── config-gen/                # Helm chart for the application
│       ├── values.yaml            # Base values (shared)
│       ├── values-staging.yaml    # Staging overrides
│       └── values-production.yaml # Production overrides (replicaCount 2, SSD, GCS backup)
└── infrastructure/
    ├── argocd/values.yaml
    ├── cert-manager/
    │   ├── values.yaml
    │   └── issuers/               # ClusterIssuer manifests + Infisical secret for CF token
    ├── cloudnativepg/values.yaml
    ├── coredns/configmap.yaml     # GKE: disabled (no hairpin needed)
    ├── dex/values.yaml
    ├── infisical/values.yaml
    ├── ingress-nginx/values.yaml  # GKE: type=LoadBalancer, replicaCount 2
    ├── kube-prometheus-stack/values.yaml
    └── reloader/values.yaml
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | Latest | Google Cloud SDK |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.32+ | `gcloud components install kubectl` |
| [Helm](https://helm.sh/) | v3.17+ | [helm.sh](https://helm.sh/docs/intro/install/) |
| A GCP project with billing enabled | — | [console.cloud.google.com](https://console.cloud.google.com) |
| A public domain | — | Pointed at the GKE LoadBalancer IP via Cloudflare DNS |
| A Cloudflare account | — | For DNS-01 TLS cert issuance |
| A GitHub OAuth App | — | For user login via Dex |

**Required GCP APIs** — enable in **APIs & Services → Enable APIs and Services**:

- Kubernetes Engine API
- Artifact Registry API
- IAM Service Account Credentials API
- Cloud Storage API

---

## Bootstrap (one-time setup)

### Phase 0 — GKE Cluster

Create the cluster from **GCP Console → Kubernetes Engine → Clusters → Create → Standard cluster**:

| Setting | Recommended value |
|---------|------------------|
| Cluster name | `config-gen-cluster` |
| Location type | Regional (3 zones for full HA) |
| Region | Closest to your users |
| Release channel | Regular |
| Node pool size | 2 nodes per zone |
| Machine type | `e2-standard-2` (2 vCPU / 8 GB) |
| Boot disk | 50 GB SSD |
| **Workload Identity** | **Enable** (required for GCS backup) |

> A zonal cluster (single zone) works but loses zone-level HA — `topologySpreadConstraints` has no effect in a single zone.

---

### Phase 1 — Connect kubectl

```bash
gcloud auth login
gcloud config set project <your-gcp-project-id>

gcloud container clusters get-credentials config-gen-cluster \
  --region <your-region>

# Verify
kubectl get nodes
```

---

### Phase 2 — Install ArgoCD

ArgoCD is bootstrapped manually with Helm once; after that it manages its own upgrades.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f infrastructure/argocd/values.yaml

# Wait until ready (~2 min)
kubectl -n argocd wait deploy/argocd-server --for=condition=available --timeout=180s

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Access UI via port-forward (before ingress is configured)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Visit https://localhost:8080  (accept self-signed cert)
```

> Change the admin password immediately after first login.

---

### Phase 3 — Hand off to GitOps

```bash
kubectl apply -f apps/app-of-apps.yaml
```

ArgoCD recurses through `apps/` and creates all child Applications.
Watch progress:

```bash
kubectl -n argocd get applications -w
```

Infrastructure apps (wave `-1`) deploy first, then the config-gen apps (wave `1`). Full sync takes 5–10 minutes.

---

### Phase 4 — Create out-of-band secrets

These secrets are **never stored in git**. Create them once after the namespaces exist.

#### 4a. cert-manager — Infisical Machine Identity for Cloudflare API token

cert-manager uses DNS-01 (Cloudflare) to issue Let's Encrypt certificates.
The Cloudflare API token is synced from Infisical into the `cert-manager` namespace by an `InfisicalSecret` CR (`infrastructure/cert-manager/issuers/infisical-cloudflare-secret.yaml`).

```bash
kubectl create namespace cert-manager   # may already exist after ArgoCD sync

kubectl create secret generic infisical-machine-identity-cert-manager \
  -n cert-manager \
  --from-literal=clientId='<infisical-machine-identity-client-id>' \
  --from-literal=clientSecret='<infisical-machine-identity-client-secret>'
```

The Infisical Machine Identity must have read access to the project and environment that stores `CF_API_TOKEN`.

#### 4b. Dex — GitHub OAuth + OIDC client secrets

1. Create a [GitHub OAuth App](https://github.com/settings/developers):
   - Homepage URL: `https://auth.<your-domain>`
   - Authorization callback URL: `https://auth.<your-domain>/callback`

2. Generate random secrets for each environment:

```bash
STAGING_SECRET=$(openssl rand -hex 32)
PROD_SECRET=$(openssl rand -hex 32)
echo "Staging:    $STAGING_SECRET"
echo "Production: $PROD_SECRET"
# Save these — you will need them in step 4c
```

3. Create the Dex secret:

```bash
kubectl create namespace dex   # may already exist

kubectl create secret generic dex-secrets -n dex \
  --from-literal=GITHUB_CLIENT_SECRET='<github-oauth-app-client-secret>' \
  --from-literal=STAGING_CLIENT_SECRET="$STAGING_SECRET" \
  --from-literal=PRODUCTION_CLIENT_SECRET="$PROD_SECRET"
```

#### 4c. config-gen — OIDC client secret (per namespace)

The value must match the corresponding `*_CLIENT_SECRET` set in step 4b.

```bash
# Production
kubectl create namespace config-gen   # may already exist
kubectl create secret generic config-gen-oidc-secret -n config-gen \
  --from-literal=OIDC_CLIENT_SECRET="$PROD_SECRET"

# Staging
kubectl create namespace config-gen-staging   # may already exist
kubectl create secret generic config-gen-oidc-secret -n config-gen-staging \
  --from-literal=OIDC_CLIENT_SECRET="$STAGING_SECRET"
```

#### 4d. Infisical operator — Machine Identity for application secrets

The Infisical operator syncs application secrets (database URL, JWT secret, etc.) into each namespace.

```bash
kubectl create namespace infisical   # may already exist

kubectl create secret generic infisical-universal-auth \
  -n infisical \
  --from-literal=clientId='<infisical-machine-identity-client-id>' \
  --from-literal=clientSecret='<infisical-machine-identity-client-secret>'
```

Then enable Infisical in the values files and set `projectSlug`:

```bash
# Edit charts/config-gen/values-production.yaml
# Edit charts/config-gen/values-staging.yaml
# Set:
#   infisical.enabled: true
#   infisical.authentication.universalAuth.secretsScope.projectSlug: "<your-slug>"
# Commit and push to GCP branch — ArgoCD auto-syncs
```

**Secrets that must exist in Infisical** (per environment):

| Key | Description |
|-----|-------------|
| `DATABASE_URL` | PgBouncer connection string: `postgres://config_gen:<password>@config-gen-db-pooler-rw:5432/config_gen?default_query_exec_mode=simple_protocol` |
| `DATABASE_DIRECT_URL` | Direct CNPG primary (used by migrations only): `postgres://config_gen:<password>@config-gen-db-rw:5432/config_gen?sslmode=require` |
| `JWT_SECRET` | Random 32+ byte string: `openssl rand -hex 32` |
| `ADMIN_USERNAME` | Initial admin account username |
| `ADMIN_PASSWORD` | Initial admin account password |

The DB password is available after CloudNativePG creates the cluster:

```bash
kubectl get secret config-gen-db-superuser -n config-gen \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

---

## DNS & TLS Setup

### 1. Get the External IP

Wait for ingress-nginx to receive an IP from the GCP Load Balancer (~2 min after sync):

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' && echo
```

### 2. Configure Cloudflare DNS

Add A records for your domain pointing to the External IP:

| Name | Type | Proxy status | Note |
|------|------|-------------|------|
| `app` | A | **Proxied (orange cloud)** | DDoS protection enabled |
| `staging` | A | **Proxied (orange cloud)** | DDoS protection enabled |
| `auth` | A | **DNS only (grey cloud)** | **Must be DNS only** |
| `argocd` | A | DNS only | |
| `grafana` | A | DNS only | |

> `auth.<domain>` (Dex OIDC) **must be DNS only**. Cloudflare's proxy modifies the TLS handshake in a way that breaks OIDC discovery (`/.well-known/openid-configuration`). The `app` and `staging` hostnames can safely use the Cloudflare proxy.

### 3. Verify TLS certificates

cert-manager issues certificates automatically once DNS propagates:

```bash
kubectl get certificates -A
# All should show READY=True within ~5 minutes of DNS propagation
```

If a certificate is stuck:

```bash
kubectl describe certificaterequest -A | grep -A5 "Message:"
kubectl get challenges -A
# Restart cert-manager if challenges appear stuck:
kubectl rollout restart deployment -n cert-manager cert-manager cert-manager-webhook cert-manager-cainjector
```

---

## GCS Database Backup (Workload Identity)

CloudNativePG continuously archives WAL to GCS and runs a daily full base backup.
This achieves **RPO ≤ 5 min** and **RTO ≤ 30 s** (standby auto-promotion).

Authentication uses GKE Workload Identity — no static credentials are stored anywhere.

### 1. Create a GCS bucket

**GCP Console → Cloud Storage → Create Bucket**:

| Setting | Value |
|---------|-------|
| Bucket name | `<your-project>-db-backup` |
| Location | Same region as your GKE cluster |
| Storage class | Standard |
| Access control | Uniform |
| Public access | Prevent public access |

### 2. Create a GCP Service Account

**GCP Console → IAM & Admin → Service Accounts → Create Service Account**:

- Name: `cnpg-backup`
- Grant role at bucket level only (more secure than project-wide):
  - **Cloud Storage → Buckets → `<bucket-name>` → Permissions → Grant Access**
  - Principal: `cnpg-backup@<project-id>.iam.gserviceaccount.com`
  - Role: **Storage Object Admin**

### 3. Bind Workload Identity

```bash
PROJECT_ID=$(gcloud config get-value project)

gcloud iam service-accounts add-iam-policy-binding \
  cnpg-backup@${PROJECT_ID}.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[config-gen/config-gen-db]"
```

> The Kubernetes ServiceAccount name equals the CloudNativePG `clusterName` value (`config-gen-db`).

### 4. Update values-production.yaml

```yaml
database:
  backup:
    enabled: true
    destinationPath: "gs://<your-bucket>/production/config-gen"
```

Commit and push — ArgoCD will apply the change and CNPG will start archiving WAL immediately.

---

## Deployed Services

| Service | Namespace | Access |
|---------|-----------|--------|
| Config Generation (production) | `config-gen` | https://app.\<domain\> |
| Config Generation (staging) | `config-gen-staging` | https://staging.\<domain\> |
| Dex OIDC | `dex` | https://auth.\<domain\> |
| ArgoCD | `argocd` | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| Prometheus / Grafana | `monitoring` | `kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80` |

Login is via **GitHub OAuth** (email domain restricted; change `oidc.allowedEmailDomains` in the values files).

---

## High Availability Design

| Tier | Mechanism | Detail |
|------|-----------|--------|
| **Ingress** | 2× ingress-nginx pods | `replicaCount: 2`; GCP LB health-checks both |
| **Ingress** | `externalTrafficPolicy: Local` | Preserves client IP; avoids extra kube-proxy hop |
| **App** | `replicaCount: 2` + HPA | Backend and frontend each run ≥ 2 replicas; HPA scales to 4 |
| **App** | `maxUnavailable: 0` rolling update | New pod passes readiness probe before old pod is removed |
| **App** | PodDisruptionBudget | `minAvailable: 1` — at least 1 pod stays up during node drain |
| **App** | `topologySpreadConstraints` | Spreads pods across GKE zones (enabled in production values) |
| **Database** | CNPG `instances: 2` | 1 primary + 1 hot-standby; automatic failover in < 30 s |
| **Database** | `storageClass: premium-rwo` | GKE SSD-backed PV (pd-ssd) for higher IOPS |
| **Database** | GCS WAL backup + ScheduledBackup | RPO ≤ 5 min; daily base backup, 14-day retention |
| **Secrets** | Infisical → Reloader | Secret rotation → K8s Secret update → rolling restart, zero downtime |
| **Monitoring** | Prometheus + Grafana + PrometheusRule | `MigrationJobFailed` critical alert; custom HTTP duration metrics |

---

## Day-2 Operations

### Change configuration

Edit the relevant `values.yaml` (or `values-staging.yaml` / `values-production.yaml`) in the `GCP` branch, commit, and push. ArgoCD detects the change and self-heals automatically.

### Reserve a static External IP (optional)

If you want the LB IP to survive cluster recreation:

```bash
gcloud compute addresses create ingress-nginx-ip --region=<region>
gcloud compute addresses describe ingress-nginx-ip --region=<region> --format='get(address)'
```

Then set `controller.service.loadBalancerIP` in `infrastructure/ingress-nginx/values.yaml`.

### Rotate the Cloudflare API token

Update the token in Infisical. The Infisical operator syncs the change to the `cloudflare-api-token-secret` within 60 seconds. cert-manager picks it up automatically on the next certificate renewal.

### Scale manually

```bash
kubectl scale deployment config-gen-backend -n config-gen --replicas=3
# HPA will take over again after the next metrics evaluation cycle
```

### Trigger a manual DB backup

```bash
kubectl apply -n config-gen -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: manual-backup
spec:
  cluster:
    name: config-gen-db
EOF
```

---

## CD Pipeline (image updates)

The application source lives in [config-generation](https://github.com/solar224/config-generation).

The GitHub Actions CD workflow:

1. Builds and pushes Docker images to `ghcr.io`.
2. Opens a pull request in this repo updating `image.backend.tag` / `image.frontend.tag` in `values-staging.yaml` (auto-merge) and `values-production.yaml` (requires approval).
3. ArgoCD detects the merged change and deploys via a `maxUnavailable: 0` rolling update.

A **PreSync hook** runs database migrations using `DATABASE_DIRECT_URL` (bypasses PgBouncer) before the new Deployment rolls out.

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
# Force hard refresh:
kubectl annotate application -n argocd <app-name> argocd.argoproj.io/refresh=hard
```

### Certificate not issuing

```bash
kubectl get certificates,certificaterequests,challenges -A
kubectl describe challenge -n <namespace> <name>
```

Common causes:
- Infisical hasn't synced the Cloudflare token yet — check `kubectl describe infisicalsecret -n cert-manager`
- `auth.<domain>` accidentally set to Cloudflare Proxied — must be DNS only
- DNS not yet propagated — wait a few minutes and retry

### Infisical secret not syncing

```bash
kubectl describe infisicalsecret -n config-gen
kubectl logs -n infisical -l app.kubernetes.io/name=secrets-operator
```

Common causes: Machine Identity credentials wrong or expired, `projectSlug` / `envSlug` mismatch.

### DB backup not working

```bash
kubectl logs -n config-gen -l cnpg.io/cluster=config-gen-db -c postgres | grep -i backup
kubectl describe backup -n config-gen
```

Common causes: Workload Identity binding missing, GCS bucket does not exist, bucket name mismatch in `values-production.yaml`.

### Get DB password

```bash
kubectl get secret config-gen-db-superuser -n config-gen \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

### User login fails with `failed to provision user`

```bash
kubectl exec -n config-gen deploy/config-gen-backend -- \
  psql "$DATABASE_DIRECT_URL" \
  -c "UPDATE user_identities SET issuer='https://auth.<domain>' WHERE issuer='<old-issuer>';"
```
