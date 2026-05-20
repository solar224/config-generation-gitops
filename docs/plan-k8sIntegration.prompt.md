# Plan: K8s Integration with Helm / ArgoCD / Infisical / Prometheus / Grafana

### TL;DR

將 `config-generation` 從 Docker Compose 遷移至 Kubernetes，使用 Helm 封裝應用，ArgoCD 實現 GitOps CD，Infisical 管理機密，Prometheus + Grafana 提供可觀測性。GitOps manifests 放在 `config-generation-gitops` repo。針對 DAU ≈ 1,000 設計：後端 2–4 replica、前端 2–3 replica、PostgreSQL HA（1 primary + 1 standby）、nginx-ingress 負載均衡。

---

## 架構總覽

```
GitHub Actions
  ├── 建 Docker image → push GHCR
  ├── production：bot 開 gitops PR → reviewer 審核合併 → ArgoCD sync
  └── staging：bot 直接 push gitops values → ArgoCD sync

                        ┌─────────────────────────────────────┐
                        │        Kubernetes Cluster           │
  Internet              │                                     │
  ────→ ingress-nginx → │  frontend (nginx) ←→ backend (Go)  │
         (L7 LB / TLS)  │                        │            │
                        │                        ▼            │
                        │               PgBouncer (pool)     │
                        │                        │            │
                        │              PostgreSQL HA          │
                        │           (primary + standby)      │
                        │                                     │
                        │  ArgoCD │ Prometheus │ Grafana      │
                        │  Infisical operator                 │
                        └─────────────────────────────────────┘
```

---

## Namespace 規劃

| Namespace | 用途 |
|---|---|
| `config-gen` | 生產環境應用 |
| `config-gen-staging` | 預備環境 |
| `argocd` | ArgoCD 控制器 |
| `monitoring` | Prometheus / Grafana |
| `infisical` | Infisical operator |
| `ingress-nginx` | nginx-ingress controller |
| `cert-manager` | TLS 憑證管理 |
| `reloader` | stakater/Reloader（Secret 變更自動 rolling restart）|

> **Namespace 建立方式**：所有 namespace 透過各 ArgoCD Application 的 `syncOptions: [CreateNamespace=true]` 自動建立（Phase 4 步驟 18、19 及所有 infra Application 均需加此選項）；不需手動 `kubectl create namespace` 或額外 namespace manifest；`argocd` namespace 在 Phase 0 bootstrap 時由 `helm install --create-namespace` 建立。

---

## 資源規格（DAU ≈ 1,000）

| 元件 | Replicas | CPU request/limit | Memory request/limit | HPA max |
|---|---|---|---|---|
| Frontend (nginx) | 2 | 50m / 200m | 64Mi / 128Mi | 3 |
| Backend (Go) | 2 | 100m / 500m | 128Mi / 256Mi | 4 |
| PgBouncer | 2 | 100m / 300m | 64Mi / 128Mi | — |
| PostgreSQL primary | 1 | 500m / 1000m | 512Mi / 1Gi | — |
| PostgreSQL standby | 1 | 200m / 500m | 256Mi / 512Mi | — |

> 後端無 session state（純 JWT），天然支援水平擴展，無需 sticky session。

---

## Repository 結構

### `config-generation`（主程式）

```
backend/
  main.go              ← 新增 /healthz, /readyz, /metrics
  handlers/router.go   ← 新增健康檢查 & metrics 路由
.github/workflows/
  cd-build-push.yml    ← 新增：build image + push GHCR；production → bot 開 gitops PR（需 reviewer 審核）；staging → bot 直接 push
```

### `config-generation-gitops`（GitOps repo）

```
config-generation-gitops/
├── apps/
│   ├── app-of-apps.yaml          ← ArgoCD root Application（管理 apps/ 下所有子 Application）；**`spec.source.directory.recurse: true` 必須設定**，否則 ArgoCD 只讀 `apps/` 根目錄，`production/`、`staging/`、`infrastructure/` 子目錄的 manifests 全部被略過
│   ├── production/
│   │   └── config-gen.yaml       ← ArgoCD Application (prod)
│   ├── staging/
│   │   └── config-gen.yaml       ← ArgoCD Application (staging)
│   └── infrastructure/           ← infra 各元件的 ArgoCD Application manifests
│       ├── cert-manager.yaml
│       ├── ingress-nginx.yaml
│       ├── cloudnativepg.yaml
│       ├── infisical.yaml
│       ├── reloader.yaml
│       └── kube-prometheus-stack.yaml
├── charts/
│   └── config-gen/
│       ├── Chart.yaml
│       ├── values.yaml           ← 共用預設值
│       ├── values-staging.yaml
│       ├── values-production.yaml
│       └── templates/
│           ├── backend/
│           │   ├── deployment.yaml
│           │   ├── service.yaml
│           │   ├── hpa.yaml
│           │   ├── pdb.yaml
│           │   └── configmap.yaml
│           ├── frontend/
│           │   ├── deployment.yaml
│           │   ├── service.yaml
│           │   ├── hpa.yaml
│           │   ├── pdb.yaml
│           │   └── configmap.yaml  ← nginx.conf（含 stub_status）供 exporter sidecar 採集
│           ├── database/
│           │   ├── cluster.yaml  ← CloudNativePG Cluster CRD
│           │   └── pgbouncer.yaml
│           ├── migrate/
│           │   └── hook.yaml     ← ArgoCD PreSync Hook for golang-migrate
│           ├── ingress/
│           │   └── ingress.yaml
│           ├── monitoring/
│           │   ├── servicemonitor-backend.yaml
│           │   ├── servicemonitor-frontend.yaml
│           │   └── grafana-dashboard-configmap.yaml
│           ├── secrets/
│           │   └── infisical-secret.yaml  ← InfisicalSecret CRD
│           └── networkpolicies/           ← 實現「前後端資料庫分離」的 K8s 網路隔離
│               ├── netpol-frontend.yaml   ← ingress: 允許 ingress-nginx → port 80、Prometheus（monitoring ns）→ port 9113；egress: 僅允許 → backend:8080
│               ├── netpol-backend.yaml    ← ingress: 允許 frontend + ingress-nginx → port 8080、Prometheus（monitoring ns）→ port 8080；egress: 僅允許 → pgbouncer:5432
│               ├── netpol-pgbouncer.yaml  ← ingress: 僅允許 backend → port 5432；egress: 允許 → postgres:5432、DNS（kube-dns port 53）
│               └── netpol-postgres.yaml   ← ingress: 允許 PgBouncer → port 5432、CloudNativePG operator（cnpg-system ns）；egress: 允許 inter-pod replication → port 5432、S3 backup（port 443）、DNS（port 53）
└── infrastructure/
    ├── argocd/
    │   └── values.yaml           ← ArgoCD Helm values（Phase 0 bootstrap 後由 App-of-Apps 管理升級）
    ├── reloader/
    │   └── values.yaml           ← stakater/Reloader Helm values（Phase 0 bootstrap）
    ├── cert-manager/
    │   └── values.yaml
    ├── ingress-nginx/
    │   └── values.yaml
    ├── cloudnativepg/
    │   └── values.yaml
    ├── infisical/
    │   └── values.yaml
    └── kube-prometheus-stack/
        └── values.yaml           ← Prometheus + Grafana stack
```

---

## 實作步驟

### Phase 0 — 一次性 Bootstrap（手動，僅初次執行）
> ArgoCD 無法被自己管理，必須先手動 bootstrap；完成後 Phase 1 起所有 infra 均交由 ArgoCD App-of-Apps 接管

0a. **ArgoCD controller** — 手動執行：`helm repo add argo https://argoproj.github.io/argo-helm && helm install argocd argo/argo-cd -n argocd --create-namespace -f infrastructure/argocd/values.yaml`；安裝完成後在 ArgoCD 建立 App-of-Apps Application，指向 gitops repo 的 `apps/` 目錄；後續 ArgoCD 自身升級亦由此 Application 管理

0b. **stakater/Reloader** — 手動執行：`helm repo add stakater https://stakater.github.io/stakater-charts && helm install reloader stakater/reloader -n reloader --create-namespace -f infrastructure/reloader/values.yaml`；**使用獨立 namespace `reloader` 而非 `kube-system`**（kube-system 在 GKE Autopilot / EKS / AKS 等 managed cluster 上通常被 PodSecurity Admission 限制部署一般 workload，可能導致 Reloader pod 無法排程）；安裝完成後由 ArgoCD App-of-Apps 接管後續升級；Reloader 監聽 K8s Secret 變更事件，當 Infisical sync 後自動對帶有 `reloader.stakater.com/auto: "true"` annotation 的 Deployment 觸發 rolling restart

### Phase 1 — 基礎設施 Helm Charts（cluster-wide）
*Phase 0 完成後由 ArgoCD 管理；所有步驟可平行安裝*

1. **cert-manager** — Helm chart `jetstack/cert-manager`，管理 Let's Encrypt TLS；建立 `ClusterIssuer`
2. **ingress-nginx** — Helm chart `ingress-nginx/ingress-nginx`，L7 負載均衡、TLS termination、`X-Real-IP` header forwarding
3. **CloudNativePG operator** — Helm chart `cnpg/cloudnative-pg`，管理 PostgreSQL HA；建立 `Cluster` CRD（1 primary + 1 standby + 10Gi PVC）；設定 `backup` stanza（WAL continuous archiving → S3-compatible object storage，如 AWS S3 / GCS / MinIO）；RPO ≤ 5 min，RTO ≤ 30s；啟用每日 base backup，並納入每週 restore drill（`cnpg restore` 至暫時 cluster，驗資料完整性後銷毀）
4. **Infisical operator** — Helm chart `infisical/secrets-operator`；在 Infisical 平台建立 project，存入 `DATABASE_URL`（含 `?default_query_exec_mode=simple_protocol`，供 app 透過 PgBouncer 存取）、`DATABASE_DIRECT_URL`（直連 CloudNativePG primary `-rw` service，**繞過 PgBouncer**，格式：`postgres://user:pass@<cluster>-rw:5432/dbname?sslmode=require`，僅供 PreSync migration hook 使用；golang-migrate 使用 `pg_advisory_lock` session 級別 advisory lock，與 PgBouncer `pool_mode = transaction` 不相容）、`JWT_SECRET`、`ADMIN_USERNAME`、`ADMIN_PASSWORD`；建立 `InfisicalSecret` CRD 同步至 K8s Secret
5. **kube-prometheus-stack** — Helm chart `prometheus-community/kube-prometheus-stack`（包含 Prometheus、Grafana、Alertmanager）；namespace `monitoring`；**必須在 `infrastructure/kube-prometheus-stack/values.yaml` 設定跨 namespace ServiceMonitor 發現**（kube-prometheus-stack 預設 `serviceMonitorSelectorNilUsesHelmValues: true`，Prometheus 只 scrape 同一 Helm release 的 ServiceMonitors，app namespace ServiceMonitors 不可見）：設定 `prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false`、`prometheus.prometheusSpec.serviceMonitorSelector: {}`（選取所有 ServiceMonitor）、`prometheus.prometheusSpec.serviceMonitorNamespaceSelector: {}`（跨 `config-gen`、`config-gen-staging` 等所有 namespace 發現）

### Phase 2 — 應用程式後端修改
*依賴 Phase 1 完成*

6. **後端健康檢查** — 在 `backend/handlers/router.go` 新增：
   - `GET /healthz` → 200 OK（liveness probe）
   - `GET /readyz` → 200 OK（驗證 DB 連線後回應，readiness probe）
7. **Prometheus metrics** — 在 `backend/main.go` 整合 `prometheus/client_golang`，expose `GET /metrics`；**metric 命名規範**：HTTP request duration histogram 命名為 `config_gen_http_request_duration_seconds`（labels: `method`、`route`、`status_code`）；**`route` label 必須使用 chi 的 route pattern（normalized），不能直接使用 raw URL path**：router 有大量動態段（`/{projectName}`、`/{envName}`、`/{templateName}`、`/{prID}`、`/{versionID}` 等），若以 raw URL 做 label 值，每個唯一的參數組合都會產生一個新 time series（高 cardinality），Prometheus TSDB 會被撐爆；實作方式：在 middleware 中以 `chi.RouteContext(r.Context()).RoutePattern()` 取得 normalized pattern（如 `/api/projects/{projectName}/envs/{envName}/values`），確保同一 route 的所有請求映射到同一個 metric label；驗證時以 `_count` suffix 確認；active DB connections gauge 命名為 `config_gen_db_open_connections`；兩者均以 `prometheus.MustRegister()` 在 server 初始化階段注冊；**`/metrics`、`/healthz`、`/readyz` 三個路由必須放在 JWT middleware 之外（public routes）**，否則 Prometheus ServiceMonitor scrape 會因 401 失敗；實作時直接在 `chi.NewRouter()` 最外層 mux 注冊，不進入 `r.Group(func(r chi.Router) { r.Use(middleware.JWTAuth ...) })` 保護區塊
8. **graceful shutdown + DB connection pool + seedAdmin 修正** — 確認 `main.go` 已處理 `SIGTERM`（Go HTTP server `Shutdown` context），若無則補上；同時在 `db/db.go` 中新增 `MaxOpenConns`、`MaxIdleConns`、`ConnMaxLifetime` 設定，透過環境變數 `DB_MAX_OPEN_CONNS`（預設 10）、`DB_MAX_IDLE_CONNS`（預設 5）、`DB_CONN_MAX_LIFETIME`（預設 5m）控制（詳見水平擴展章節）；**同時修正 `main.go` 的 `seedAdmin` race condition**：`users.username` 有 `UNIQUE NOT NULL` 約束，minReplicas: 2 下兩個 pod 同時啟動時都通過 `SELECT EXISTS`（回傳 false）後嘗試 INSERT，第二個 pod 因 UNIQUE violation 導致 `log.Fatalf` crash 進入 CrashLoopBackOff；修正：將 INSERT 改為 `INSERT INTO users (username, display_name, password_hash, superuser) VALUES ($1, $2, $3, true) ON CONFLICT (username) DO NOTHING`，使 seed 操作 idempotent

### Phase 3 — Helm Chart 開發
*依賴 Phase 2 完成；可平行開發 frontend/backend/database templates*

9. **`charts/config-gen/Chart.yaml`** — 定義 chart name、version、appVersion
10. **後端 Deployment template** — `imagePullPolicy: IfNotPresent`（images 以 git SHA 標記，SHA 是 content-addressed 的 immutable identifier；`Always` 會在每次 pod 重啟時重拉相同內容，浪費 Registry 頻寬並拖慢啟動時間；`IfNotPresent` 對 SHA tag 是正確且高效的設定）、2 replicas、envFrom（Infisical Secret）、liveness/readiness probe（`/healthz`, `/readyz`）、anti-affinity（spread across nodes）
11. **前端 Deployment template** — nginx image；**`templates/frontend/configmap.yaml`** 需包含三段 location：`/api/` proxy to backend Service、SPA fallback `/`、以及 `location /nginx-status { stub_status on; allow 127.0.0.1; deny all; }`（供 exporter sidecar 採集，不對外暴露）；**K8s ConfigMap 的 nginx.conf 改為 `listen 80;`**（docker-compose 版用 `listen 3000;` 是為了避免與宿主機衝突，K8s pod 內不需要此限制；對應 Deployment `containerPort: 80`、Service `targetPort: 80`）；**ConfigMap 掛載路徑必須與 Dockerfile 一致**：Frontend Dockerfile 是 `COPY nginx.conf /etc/nginx/conf.d/default.conf`，volumeMount 需為 `mountPath: /etc/nginx/conf.d/default.conf` 並加 `subPath: default.conf`（若掛載至整個 conf.d/ 目錄會清空 nginx 其他預設設定）；Deployment spec 需同時加入 nginx-prometheus-exporter sidecar container（image: `nginx/nginx-prometheus-exporter`，args: `--nginx.scrape-uri=http://127.0.0.1/nginx-status`，containerPort: 9113）；**注意：現有 `frontend/nginx.conf` 無 stub_status 且 listen 3000，Helm chart 必須使用獨立 ConfigMap 完整覆蓋，不能沿用 Dockerfile 內建版本**；**`templates/frontend/service.yaml` 必須同時開放兩個 named port**：`name: http, port: 80, targetPort: 80`（app traffic）和 `name: metrics, port: 9113, targetPort: 9113`（exporter sidecar）；ServiceMonitor 以 `endpoints[].port: metrics` 指定 scrape target，若 Service 缺少此 named port，Prometheus 無法 discover 到 frontend scrape endpoint
12. **HPA templates** — 後端 min=2/max=4 at 70% CPU；前端 min=2/max=3 at 70% CPU
13. **PodDisruptionBudget templates** — 後端和前端各設 `minAvailable: 1`
14. **NetworkPolicy templates** — 於 `templates/networkpolicies/` 建立 4 個 NetworkPolicy（**前提**：cluster CNI 必須支援 NetworkPolicy，如 Calico、Cilium、AWS VPC CNI with policy enforcement；裸 K8s + Flannel 預設不支援，需確認 cluster 環境）：`netpol-frontend.yaml`（ingress: ingress-nginx → port 80 + Prometheus monitoring ns → port 9113；egress: → backend:8080）、`netpol-backend.yaml`（ingress: frontend + ingress-nginx → port 8080 + Prometheus monitoring ns → port 8080；egress: → pgbouncer:5432）、`netpol-pgbouncer.yaml`（ingress: backend → port 5432；egress: → postgres:5432 + DNS port 53）、`netpol-postgres.yaml`（ingress: PgBouncer + CloudNativePG operator cnpg-system ns → port 5432；egress: inter-pod replication port 5432 + S3 backup port 443 + DNS port 53；**不加 `egress: deny all`**，會阻斷 WAL archiving 與 operator 控制平面流量）
15. **DB migrate PreSync Hook** — 將 golang-migrate 改為 ArgoCD **PreSync Hook**（annotation `argocd.argoproj.io/hook: PreSync`，delete policy `argocd.argoproj.io/hook-delete-policy: HookSucceeded`）；避免普通 Job 在 ArgoCD 後續 sync 時因 immutable resource 導致 drift 或 sync fail；PreSync 階段會在主資源同步之前執行，相當於原 docker-compose 的 `service_completed_successfully` 前置依賴；**Hook Job 使用 backend image 並 override command**（`command: ["/usr/local/bin/migrate", "-path=/migrations", "-database=$(DATABASE_DIRECT_URL)", "up"]`）；**`DATABASE_DIRECT_URL` 直連 PostgreSQL primary（繞過 PgBouncer）**：golang-migrate Postgres driver 使用 `pg_advisory_lock` 建立 session 級別 advisory lock（透過 `*sql.Conn` 固定 server 連線），此鎖在 transaction 結束後即失效，與 PgBouncer `pool_mode = transaction` 不相容；migration hook 必須直連 CloudNativePG primary `-rw` service，不得透過 PgBouncer；**注意：backend 最終 image（`alpine:3.21`）只有 `/server` binary 與 `/migrations/` 目錄，缺少 `migrate` CLI 執行檔**；需在 `backend/Dockerfile` builder stage 加入編譯步驟：`RUN go build -o /migrate github.com/golang-migrate/migrate/v4/cmd/migrate`（go.mod 已有 `golang-migrate/v4 v4.19.1`，不需額外下載），最終 stage 再 `COPY --from=builder /migrate /usr/local/bin/migrate`；Hook 與 backend 共用同一 image，版本自動與 go.mod 鎖定一致
16. **Ingress template** — `nginx.ingress.kubernetes.io` annotations、TLS、路由 `/api/*` → backend、`/` → frontend；**hostname 需在 values 檔中參數化**：`values-production.yaml` 設 `ingress.host: app.yourdomain.com`，`values-staging.yaml` 設 `ingress.host: staging.yourdomain.com`（兩個 ArgoCD Application 部署至不同 namespace，共用同一個 ingress-nginx controller，以 hostname 區分流量）；TLS 憑證由 cert-manager `ClusterIssuer` 自動簽發，annotation: `cert-manager.io/cluster-issuer: letsencrypt-prod`
17. **ServiceMonitor templates** — 後端 `ServiceMonitor` 指向 public `/metrics` 路由；前端 **nginx 本身無 Prometheus endpoint**，改用 `nginx-prometheus-exporter` sidecar（nginx `stub_status` → exporter，port 9113），不需修改應用程式碼；`servicemonitor-frontend.yaml` 以 `endpoints[].port: metrics` 指定 scrape target（對應 step 11 的 frontend Service named port `metrics: 9113`）；**注意：`nginx stub_status` 僅提供 active connections、request count，無法提供 upstream response time**；upstream 延遲 metric 應來自 ingress-nginx controller 的 Prometheus 指標（kube-prometheus-stack 預設已 scrape ingress-nginx，metric: `nginx_ingress_controller_request_duration_seconds`）；Grafana dashboard ConfigMap 包含：後端 API request latency（`config_gen_http_request_duration_seconds` histogram）、error rate、DB connections（`config_gen_db_open_connections`）、nginx request rate（frontend exporter，來自 stub_status）、ingress request latency（ingress-nginx controller metrics，可取代 upstream response time）

### Phase 4 — GitOps ArgoCD 設定
*依賴 Phase 3 完成*

18. **ArgoCD App-of-Apps** — root Application 指向 `apps/` 目錄，`syncPolicy: automated`（prune + selfHeal）；**`app-of-apps.yaml` 必須設定 `spec.source.directory.recurse: true`**：ArgoCD directory application 預設只讀取 path 根目錄，不自動掃描子目錄，未設定時 `production/`、`staging/`、`infrastructure/` 下的 Application manifests 全部被忽略，root Application 顯示 `Synced` 但實際未建立任何 child Application；App-of-Apps 遞迴管理 `apps/` 下所有子 Application，包含 `apps/production/`、`apps/staging/` 與 **`apps/infrastructure/`**；`apps/infrastructure/*.yaml` 共 6 個 Application，分別對應 `infrastructure/` 下的 Helm values，以 Helm chart source + values file 模式部署 cert-manager、ingress-nginx、CloudNativePG、Infisical、Reloader、kube-prometheus-stack；**若缺少這次 Application manifests，Phase 1 的 infra 元件將僅實行手動安裝一次，後續升級無法由 ArgoCD 管理**；**跨 Application 安裝順序（critical）**：ArgoCD 不保證 child Application 之間有先後順序，若 infra CRD（`Cluster`、`InfisicalSecret`、`ServiceMonitor` 等）尚未就緒而 app Application 先 sync 就會立即 fail；解法：在 `apps/infrastructure/*.yaml` 的每個 Application manifest 加上 `metadata.annotations: argocd.argoproj.io/sync-wave: "-1"`，在 `apps/production/config-gen.yaml` 與 `apps/staging/config-gen.yaml` 加上 `argocd.argoproj.io/sync-wave: "1"`；App-of-Apps 每次 sync 時，wave -1 的 infra Applications 永遠先被觸發，待其 Healthy 後才繼續 wave 1 的 app Applications
19. **Staging Application** — 指向 `charts/config-gen` + `values-staging.yaml`，namespace `config-gen-staging`；**加入 `syncOptions: [CreateNamespace=true]`**（ArgoCD 在 namespace 不存在時自動建立，無需手動 `kubectl create namespace`；infra Applications 同樣需加此選項）
20. **Production Application** — 指向 `charts/config-gen` + `values-production.yaml`，namespace `config-gen`；**同樣加入 `syncOptions: [CreateNamespace=true]`**
21. **Sync Wave 兩層設計** — **跨 Application 層（見 step 18）**：infra Applications wave `-1`、app Applications wave `1`，確保 CRD 在 app chart 渲染前就緒；**Application 內部層**：DB migrate 採 PreSync Hook（無需 wave）；Sync 階段排序：backend（wave 2）→ frontend（wave 3）；ArgoCD PreSync 階段自動在所有 wave 之前執行，等待 Hook Job `Completed` 後才繼續；**兩層 wave 缺一不可**，僅設置 Application 內部 wave 無法解決首次 bootstrap 時 CRD 不存在的問題

### Phase 5 — CI/CD Pipeline 整合
*依賴 Phase 3、4 完成*

22. **新增 `.github/workflows/cd-build-push.yml`** — Trigger: push to `main` branch
    - Build & push backend image → `ghcr.io/<org>/config-gen-backend:<sha>`
    - Build & push frontend image → `ghcr.io/<org>/config-gen-frontend:<sha>`
    - **前置條件（一次性設定）**：`GITHUB_TOKEN` 僅能存取當前 repo（`config-generation`），對 `config-generation-gitops` 的 push / PR 操作會得到 403；**建議使用 GitHub App installation token（优先於個人 PAT）**：GitHub App 身份明確（PR author 顯示為 `your-app-name[bot]`）、Token 短期有效（1h）、不綁定個人帳號（PAT 綁定個人，人員離職需輪替）；建立 GitHub App → 安裝至 `config-generation-gitops` repo（授予 `Contents: write` + `Pull requests: write`）→ 將 App ID 與 Private Key 存入 `config-generation` repo 的 Actions secrets（`GITOPS_APP_ID` + `GITOPS_APP_PRIVATE_KEY`）；workflow 中以 `actions/create-github-app-token` action 生成 installation token 作為 `GH_TOKEN` 使用；**將不再使用 `github-actions[bot]` 這個身份**（該身份綁定於內建 `GITHUB_TOKEN`，與 GitHub App token 或 PAT 無關）
    - CI **不直接修改** production values；改由 bot（GitHub App，`your-app-name[bot]`）向 `config-generation-gitops` 開 Pull Request，更新 `values-production.yaml` 中的 image tag
    - 該 gitops PR 受 **GitHub environment `production` 保護**（required reviewers），需人工審核合併
    - PR 合併後，ArgoCD 偵測 gitops repo 變更，自動 sync 到 production
23. **Staging promotion** — 目前 repo 只有 `main` 分支（無 `develop`）；staging 與 production 共用同一個 push to `main` trigger：同一個 CI job 在 build image 後，(a) 直接 push 更新 `values-staging.yaml`（ArgoCD 立即 sync staging），並 (b) 開 gitops PR 更新 `values-production.yaml`（等待 reviewer）；兩個動作以同一個 `$GITHUB_SHA` 的 image tag 操作，保持 staging 與 production 指向同一個 commit 的 image；**若未來引入 `develop` 分支**，可將 staging trigger 改為 push to `develop`，production trigger 維持 push to `main`，兩者在同一 workflow file 以 `if: github.ref == ...` 分路執行

---

## 關鍵設計決策

### 高可用（HA）
- Backend / Frontend：minimum 2 replicas + PDB `minAvailable: 1`
- PostgreSQL：CloudNativePG primary + standby，自動 failover（RTO ≤ 30s）；**WAL continuous archiving** 至 S3-compatible storage，每日 base backup（RPO ≤ 5 min）；每週執行 restore drill（`cnpg restore` 還原至暫時 cluster，驗資料後銷毀）
- PgBouncer：2 replicas，pool mode = transaction（最省連線數，適合 Go 短連線）；**pgx + PgBouncer transaction mode 相容性（必須處理，否則上線後出現間歇性 DB 錯誤）**：pgx stdlib 預設以 `extended query protocol` 發送查詢（會建立 server-side prepared statement cache），PgBouncer transaction pool 無法跨 transaction 保留 server session，因此 prepared statement 在 transaction 結束後立即失效，下次使用時報 `prepared statement does not exist` 錯誤；**修正方式**：`DATABASE_URL` 加入 `?default_query_exec_mode=simple_protocol`（使用 simple query protocol，完全避免 prepared statement）；此參數必須寫入 Infisical secret template（`DATABASE_URL` 範本值）並在 Phase 1 的 Infisical 設定說明中標注，確保不被遺漏
- anti-affinity：`preferredDuringSchedulingIgnoredDuringExecution` 確保 pods 分散至不同 node

### 水平擴展
- 後端完全無狀態（JWT，無 in-memory session），直接 HPA 擴展
- 前端 nginx 靜態服務，直接 HPA 擴展
- PostgreSQL read replicas 可未來擴充（目前 DAU 1,000 不需要讀寫分離）
- **DB connection pool 控制**（Phase 2 先行完成，否則 HPA 上線會壓爆 PgBouncer）：
  - `db/db.go` 新增 `MaxOpenConns = DB_MAX_OPEN_CONNS`（預設 10）、`MaxIdleConns = DB_MAX_IDLE_CONNS`（預設 5）、`ConnMaxLifetime = DB_CONN_MAX_LIFETIME`（預設 5m）
  - PgBouncer `pool_size` 公式：`backend_max_replicas × MaxOpenConns × 1.1`（10% buffer）
  - HPA max replicas 的連線上限不得超過 PgBouncer pool_size

  | 情境 | Backend replicas | MaxOpenConns/pod | PgBouncer pool_size |
  |---|---|---|---|
  | 正常 | 2 | 10 | 25（含 buffer）|
  | HPA 最大 | 4 | 10 | 45（含 buffer）|

### 高效搜尋

**現有索引（已存在，無需新增）**：
- `idx_deployments_lookup` — `(project_id, environment_id, status, created_at DESC)`（migration 000005）
- `idx_pull_requests_project_status` — `(project_id, status)`（migration 000006）
- `idx_pull_requests_gv_name_status` — `(global_values_name, status)` WHERE NOT NULL（migration 000010）
- `idx_global_values_latest` — `(name, version_id DESC)`（migration 000004）
- `projects.name UNIQUE`（implicit B-tree，migration 000002）

**現有 API 缺口（DAU 1,000 下為低優先度，列入 backlog）**：
- 所有列表 API 目前無 pagination（`projects.List`、`global_values.List`、`pull_requests.List`），資料量增長後應補 `?page=&limit=` 參數
- `pull_requests.List` 只支援 `global_values_name` 過濾，缺少 `status`、`author_id` 欄位過濾
- 未來若需全文搜尋可啟用 PostgreSQL `pg_trgm` extension + GIN index（不需引入 Elasticsearch）

### 負載均衡
- L7：nginx-ingress（單一 entrypoint，基於 path routing）
- L4：Kubernetes ClusterIP Service（round-robin across pods）
- 無需 sticky session（JWT stateless）

### 前後端資料庫分離
- 三個獨立 Deployment，各自 HPA + PDB
- backend 只能連 PgBouncer Service（不直接暴露 PostgreSQL port）
- frontend 只能連 backend Service（/api proxy），不接觸 DB
- **以上隔離僅在架構設計層面成立，若沒有 NetworkPolicy，同 namespace 內所有 Pod 預設可互相存取任意 port**；Phase 3 step 14 於 `templates/networkpolicies/` 建立 4 個 K8s NetworkPolicy（見 chart tree；**前提**：cluster CNI 必須支援 NetworkPolicy，如 Calico、Cilium、AWS VPC CNI with policy enforcement；裸 K8s + Flannel 預設不支援）：
  - `netpol-frontend`：ingress 允許 ingress-nginx namespace Pod → port 80、Prometheus（monitoring namespace）→ port 9113；egress 僅允許 → backend Service port 8080
  - `netpol-backend`：ingress 允許 frontend Pod、ingress-nginx Pod → port 8080、Prometheus（monitoring namespace）→ port 8080；egress 僅允許 → PgBouncer Service port 5432
  - `netpol-pgbouncer`：ingress 僅允許 backend Pod → port 5432；egress 允許 → PostgreSQL pod port 5432、DNS（kube-dns port 53）
  - `netpol-postgres`：ingress 允許 PgBouncer Pod → port 5432、CloudNativePG operator（cnpg-system namespace）；egress 允許 inter-pod replication → port 5432（同 cluster label）、S3 backup（port 443）、DNS（port 53）；**不加 `egress: deny all`**（會阻斷 WAL archiving 與 operator 控制平面流量）

### Secret 管理（Infisical）
- `InfisicalSecret` CRD 自動將 Infisical secrets sync 為 K8s Secret
- 後端 Pod 透過 `envFrom` 引用該 K8s Secret，不在 manifests 中硬編碼任何密碼
- **Secret rotation 機制**：K8s 環境變數只在 Pod 建立時展開一次，執行中的 Pod 不感知 Secret 更新；需於 Phase 0 安裝 [stakater/Reloader](https://github.com/stakater/Reloader)，並在 Deployment 加上 annotation `reloader.stakater.com/auto: "true"`；Infisical secret 更新 → K8s Secret 自動 sync → Reloader 偵測 Secret 變更 → 觸發 rolling restart，確保所有 Pod 重新載入最新密鑰
- **輪轉注意事項**：`DATABASE_URL` 輪轉需先預熱新連線再排空舊連線（PgBouncer `PAUSE` → 切換 → `RESUME`）；`JWT_SECRET` 輪轉會使既有 JWT token 失效（24h expiry），可提供 grace period（雙 key 轉換期）或允許使用者重新登入

---

## 關鍵檔案（需新增/修改）

| 檔案 | 動作 | 說明 |
|---|---|---|
| `backend/handlers/router.go` | 修改 | 新增 `/healthz`, `/readyz`, `/metrics` 路由 |
| `backend/main.go` | 修改 | 新增 prometheus metrics middleware、graceful shutdown、`seedAdmin` ON CONFLICT 修正 |
| `backend/db/db.go` | 修改 | 新增 DB connection pool 設定（MaxOpenConns、MaxIdleConns、ConnMaxLifetime）環境變數化 |
| `backend/Dockerfile` | 修改 | builder stage 加 `RUN go build -o /migrate github.com/golang-migrate/migrate/v4/cmd/migrate`；最終 stage 加 `COPY --from=builder /migrate /usr/local/bin/migrate`，供 PreSync Hook 使用 |
| `backend/go.mod` | 修改 | 新增 `prometheus/client_golang` dependency |
| `config-generation` Actions secrets | 設定 | 新增 `GITOPS_APP_ID` + `GITOPS_APP_PRIVATE_KEY`（GitHub App installation token；PR author 顯示為 `app-name[bot]`，有利稽核；優先於個人 PAT）|
| `config-generation-gitops/apps/infrastructure/*.yaml` | 新增 | 6 個 infra ArgoCD Application manifests（cert-manager、ingress-nginx、cloudnativepg、infisical、reloader、kube-prometheus-stack）|
| `.github/workflows/cd-build-push.yml` | 新增 | CD pipeline：build & push image；production → bot 開 gitops PR；staging → bot 直接 push gitops |
| `config-generation-gitops/charts/config-gen/**` | 新增 | 完整 Helm chart（23個 template files，含 `frontend/configmap.yaml`、4 個 NetworkPolicy）|
| `config-generation-gitops/apps/**` | 新增 | ArgoCD App-of-Apps manifests（`app-of-apps.yaml` 需設定 `spec.source.directory.recurse: true`）|
| `config-generation-gitops/infrastructure/reloader/values.yaml` | 新增 | stakater/Reloader Helm values（Phase 0 手動 bootstrap，後由 ArgoCD 管理）|
| `config-generation-gitops/infrastructure/**` | 新增 | 其餘 cluster-wide Helm values（argocd、cert-manager、ingress-nginx、cloudnativepg、infisical、kube-prometheus-stack）；**kube-prometheus-stack values.yaml 需設定 `serviceMonitorSelectorNilUsesHelmValues: false`（詳見 Phase 1 step 5）**|

---

## 驗證步驟

### 部署驗證
1. **本地 K8s 測試** — 使用 `kind` 或 `minikube` 本地建立 cluster，`helm install --dry-run` 確認 template render 無誤
2. **DB migrate PreSync Hook** — 確認 PreSync Hook Job 使用 `DATABASE_DIRECT_URL`（直連 PostgreSQL primary，非 PgBouncer）；確認 `kubectl logs -l argocd.argoproj.io/hook=PreSync` 顯示所有 migrations applied；再次 sync 後 Hook Job 被清除並能重新建立執行
3. **健康檢查（無需 JWT）** — `curl http://<backend>/healthz` 與 `curl http://<backend>/readyz` 無需 Authorization header 回傳 200；`kubectl get pods` 所有 pods Ready
4. **ArgoCD sync** — ArgoCD UI 顯示 Application `Synced` + `Healthy`
5. **Prometheus 指標** — `kubectl port-forward svc/prometheus 9090` 確認 `config_gen_http_request_duration_seconds_count` metric 存在（histogram 自動產生 `_count` suffix，ServiceMonitor scrape 成功、無 401）；同時確認 `config_gen_db_open_connections` gauge 存在
6. **Grafana dashboard** — 確認 API request rate、P99 latency、DB connections、nginx request rate 圖表正常顯示
7. **Infisical secret sync** — `kubectl get secret config-gen-secrets -o yaml` 確認 keys 存在（values base64 encoded）
8. **NetworkPolicy 驗證** — 確認流量隔離正確：(a) backend pod 可連 PgBouncer port 5432，但無法直連 PostgreSQL port 5432；(b) Prometheus（monitoring namespace pod）可 reach backend:8080（`/metrics`）與 frontend:9113；(c) frontend pod 只能連 backend:8080，無法直連 PgBouncer；(d) 從非授權 namespace pod 嘗試連線確認被 NetworkPolicy reject（`Connection timed out`）

### 穩定性驗證（Acceptance Criteria）
9. **HPA + 連線池壓測** — `k6` 以 200 req/s 持續 5 分鐘；驗證 HPA 觸發 scale-out；監控 PgBouncer `cl_active` 連線數不超過 pool_size；後端 pod 無 `connection pool exhausted` 錯誤
10. **PostgreSQL HA failover** — 刪除 primary pod，確認 standby 在 30s 內晉升 primary；應用全程回傳 2xx（短暫 5xx 可接受）；驗證無資料遺失
11. **PostgreSQL restore drill** — 從最新 backup 執行 `cnpg restore` 至暫時 cluster；驗證資料完整性後銷毀；RPO ≤ 5 min，RTO ≤ 30 min
12. **Secret rotation drill** — 更新 Infisical 中的 `JWT_SECRET`；驗證 K8s Secret 自動 sync；驗證 Reloader 觸發 rolling restart；驗證舊 token 失效後新 token 可正常使用
13. **Production promotion flow** — push commit to main → GitHub Actions build image → bot 開 gitops PR → reviewer approve & merge → ArgoCD auto-sync → new pod rolling update；全程不需手動修改 production manifests
14. **Rollback drill** — ArgoCD UI 執行 rollback 至前一版本；確認 pods 回到舊 image；確認 DB migration backward-compatible（不需 down migration）

---

## 範圍邊界（刻意不含）

- **Elasticsearch / OpenSearch** — DAU 1,000 下 PostgreSQL FTS 已足夠
- **KEDA**（event-driven scaling） — CPU-based HPA 已足夠，KEDA 預留未來
- **Service Mesh（Istio/Linkerd）** — 過度工程，DAU 1,000 不需要
- **Multi-region / Global CDN** — DAU 1,000 不需要
- **Database read/write splitting at app layer** — PgBouncer pool 已足夠

---

## 延伸考量

1. **Container Registry 選擇** — 建議使用 GitHub Container Registry（GHCR）與現有 GitHub Actions 整合，免費 public；private 需付費或使用 DockerHub free tier
2. **Cluster 供應商** — 計畫未指定 cloud provider，圖表可適用 GKE / EKS / AKS / on-prem；各家 StorageClass 和 LoadBalancer class 設定需調整
3. **Infisical 部署模式** — 可選 Infisical Cloud（SaaS）或 self-hosted；self-hosted 需額外 PostgreSQL instance
