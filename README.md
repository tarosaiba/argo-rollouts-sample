# OpenShift GitOps x OpenTelemetry Demo — Continuous Delivery Sample

OpenShift GitOps (ArgoCD) と OpenTelemetry Demo を題材にした Continuous Delivery サンプル実装。

## 概要

- **プラットフォーム**: OpenShift 4.18 + OpenShift GitOps Operator v1.14
- **環境**: dev / stg / prod の 3 面
- **マニフェスト管理**: Helm chart を `helm template` でフラット化 → Kustomize で管理
- **Progressive Delivery**: Argo Rollouts による Blue/Green デプロイ
- **Analysis**: HTTP Web チェックによる自動判定
- **Promote**: 全環境 Manual Promote
- **CI Pipeline**: Tekton (OpenShift Pipelines) による Wave 方式段階的リリース

## ディレクトリ構成

```
├── bootstrap/
│   ├── namespaces.yaml           # Namespace 定義 + managed-by ラベル
│   ├── cluster-rbac.yaml         # ClusterRole/Binding (Grafana, OTel, Prometheus)
│   ├── scc-anyuid.yaml           # anyuid SCC ClusterRoleBinding
│   ├── rollout-manager.yaml      # Argo Rollouts コントローラー
│   └── root-app.yaml             # App of Apps の起点
├── argocd/
│   ├── projects/                 # AppProject (dev / stg / prod)
│   ├── applicationsets/          # dev/stg を Auto Sync で展開
│   └── applications/             # prod は Manual Sync
├── otel-demo/
│   ├── base/
│   │   ├── manifests/            # helm template で render 済みマニフェスト
│   │   ├── patches/              # Rollout, Route, AnalysisTemplate 等
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/
│       ├── stg/
│       └── prod/
├── tekton/
│   ├── tasks/                    # update-and-sync Task
│   ├── pipelines/                # progressive-release Pipeline
│   └── pipelineruns/             # PipelineRun テンプレート
├── scripts/
│   └── render-chart.sh           # Helm chart 再 render スクリプト
├── docs/
│   ├── plan.md                   # 実装計画 (Single Source of Truth)
│   ├── architecture.md           # 構成図・技術スタック
│   ├── promotion-flow.md         # 昇格手順
│   ├── demo-scenario.md          # デモシナリオ
│   └── pipeline.md               # Tekton Pipeline 詳細
└── Makefile
```

## ArgoCD 構成

### App of Apps パターン

本リポジトリは **App of Apps** パターンを採用している。
`bootstrap/root-app.yaml` が起点となり、`argocd/` ディレクトリ配下の全リソース（AppProject, ApplicationSet, Application）を再帰的に管理する。

```
otel-demo-bootstrap (root Application)
│  source: argocd/  directory.recurse: true
│  syncPolicy: automated (prune + selfHeal)
│
├── AppProject: otel-demo-dev
├── AppProject: otel-demo-stg
├── AppProject: otel-demo-prod
│
├── ApplicationSet: otel-demo          ← dev/stg を生成
│   ├── Application: otel-demo-dev     (Auto Sync)
│   └── Application: otel-demo-stg    (Auto Sync)
│
└── Application: otel-demo-prod       (Manual Sync)
```

### ApplicationSet (dev / stg)

**ファイル**: `argocd/applicationsets/otel-demo.yaml`

List Generator で dev と stg の 2 つの Application を動的に生成する。

```yaml
generators:
  - list:
      elements:
        - { env: dev,  namespace: otel-demo-dev,  project: otel-demo-dev }
        - { env: stg,  namespace: otel-demo-stg,  project: otel-demo-stg }
```

生成される Application は以下のパラメータを持つ:

| パラメータ | 値 |
|-----------|---|
| `source.path` | `otel-demo/overlays/{{env}}` |
| `source.targetRevision` | `main` |
| `destination.namespace` | `otel-demo-{{env}}` |
| `syncPolicy.automated.prune` | `true` — Git から削除されたリソースをクラスタからも削除 |
| `syncPolicy.automated.selfHeal` | `true` — クラスタ上での手動変更を Git の状態に自動修復 |
| `syncOptions` | `CreateNamespace=false`, `PruneLast=true` |

### Application (prod)

**ファイル**: `argocd/applications/otel-demo-prod.yaml`

prod は ApplicationSet に含めず、独立した Application として定義する。

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=false
    - PruneLast=true
  # automated セクションなし → Manual Sync
```

**`automated` セクションが存在しない** = Manual Sync。
Git に変更を push しても ArgoCD は自動で sync しない。
`OutOfSync` 状態になったことを確認してから、明示的に Sync を実行する。

### Sync の実行方法

**Auto Sync (dev/stg)**:

Git push 後、ArgoCD のポーリング間隔（デフォルト 3 分）または Webhook で自動検知 → 自動 Sync。

**Manual Sync (prod)**:

```bash
# ArgoCD UI から Sync ボタン、または CLI:
oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

### syncPolicy パラメータ解説

| パラメータ | dev/stg | prod | 説明 |
|-----------|---------|------|------|
| `automated` | あり | **なし** | 自動 Sync の有効/無効 |
| `automated.prune` | `true` | — | Git から削除されたリソースをクラスタからも自動削除 |
| `automated.selfHeal` | `true` | — | `kubectl edit` 等の直接変更を Git 状態に自動修復 |
| `CreateNamespace` | `false` | `false` | Namespace は bootstrap で事前作成済みのため自動作成しない |
| `PruneLast` | `true` | `true` | 削除は新リソース作成後に実行（安全な順序制御） |

### AppProject によるスコープ制御

**ファイル**: `argocd/projects/{dev,stg,prod}-project.yaml`

各環境に専用の AppProject を定義し、以下を制限する:

```yaml
spec:
  sourceRepos:
    - https://github.com/tarosaiba/argo-rollouts-sample.git  # このリポジトリのみ
  destinations:
    - namespace: otel-demo-{env}       # 自環境の Namespace のみ
      server: https://kubernetes.default.svc
  clusterResourceWhitelist: []         # ClusterRole 等の作成を禁止
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"                        # Namespace 内は全リソース許可
```

- **sourceRepos**: 指定リポジトリ以外からのデプロイを禁止
- **destinations**: 他環境の Namespace への誤デプロイを防止
- **clusterResourceWhitelist**: 空 = Cluster スコープリソースの作成不可（ClusterRole 等は `bootstrap/cluster-rbac.yaml` で管理）

## 環境別ポリシー

| 環境 | Sync | Self-heal | Prune | Rollout | Analysis | Promote |
|------|------|-----------|-------|---------|----------|---------|
| dev  | Auto | あり | あり | Blue/Green | あり (Web check) | Manual |
| stg  | Auto | あり | あり | Blue/Green | あり (Web check) | Manual |
| prod | **Manual** | **なし** | あり (Manual時) | Blue/Green | あり (Web check) | Manual |

### 環境別 Overlay の違い

| 環境 | 特徴 | Kustomize overlay |
|------|------|------------------|
| dev | 全コンポーネント稼働、load-generator は 1 replica | `overlays/dev/` |
| stg | **全 Deployment/Rollout を 0 replica** に縮退（コスト削減） | `overlays/stg/` |
| prod | 全コンポーネント稼働（base のデフォルト replica） | `overlays/prod/` |

各 overlay 共通で、AnalysisTemplate の namespace 引数を自環境に書き換えるパッチを含む（Argo Rollouts コントローラーは `argo-rollouts` ns で動作するため、FQDN で Service を参照する必要がある）。

## Argo Rollouts (Blue/Green)

frontend のみ Deployment → Rollout に変換し、Blue/Green 戦略を適用している。

```
Rollout (frontend)
├── activeService:  frontend          ← 本番トラフィック
├── previewService: frontend-preview  ← 新バージョンのプレビュー
├── autoPromotionEnabled: false       ← 手動 Promote 必須
└── prePromotionAnalysis:
    └── AnalysisTemplate: http-success-rate
        ├── HTTP GET → frontend-preview.{ns}.svc:8080/
        ├── interval: 30s, count: 4 (2分間)
        ├── failureLimit: 1
        └── successCondition: result.status == "200"
```

**デプロイの流れ**:
1. Git push → ArgoCD Sync で Rollout spec が更新される
2. preview ReplicaSet が作成され、新 Pod が起動
3. `prePromotionAnalysis` が自動実行 — preview Service 経由で HTTP 200 を確認
4. Analysis 成功 → Rollout が **Paused** になり、手動 Promote を待機
5. Promote 実行 → active Service が新 ReplicaSet に切り替わる
6. 旧 ReplicaSet がスケールダウン → **Healthy**

**Promote コマンド** (`kubectl-argo-rollouts` プラグイン未導入のため `oc patch` を使用):

```bash
oc patch rollout.argoproj.io frontend -n otel-demo-{env} \
  --type merge --subresource status \
  -p '{"status":{"promoteFull":true}}'
```

## 前提条件

- OpenShift 4.x クラスタ
- OpenShift GitOps Operator (インストール済み)
- OpenShift Pipelines Operator (Tekton Pipeline 使用時)
- Argo Rollouts CRD (GitOps Operator に含まれる)
- `oc` / `helm` CLI
- GitOps Operator Subscription に以下の env 設定:
  ```
  CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES=argo-rollouts
  ```

## クイックスタート

```bash
# 1. (任意) Helm chart を再 render
make render-chart

# 2. 前提条件を適用 (Namespace, SCC, RolloutManager) → App of Apps を投入
make apply-bootstrap

# 3. prod を Manual Sync
make sync-prod
```

## GitOps で管理されるもの

| リソース | 管理方法 | ファイル |
|---------|---------|---------|
| Namespace + ラベル | `bootstrap/` 手動 apply | `bootstrap/namespaces.yaml` |
| Cluster RBAC | `bootstrap/` 手動 apply | `bootstrap/cluster-rbac.yaml` |
| anyuid SCC | `bootstrap/` 手動 apply | `bootstrap/scc-anyuid.yaml` |
| RolloutManager | `bootstrap/` 手動 apply | `bootstrap/rollout-manager.yaml` |
| AppProject | App of Apps (ArgoCD) | `argocd/projects/*.yaml` |
| ApplicationSet | App of Apps (ArgoCD) | `argocd/applicationsets/*.yaml` |
| Application (prod) | App of Apps (ArgoCD) | `argocd/applications/*.yaml` |
| OTel Demo 全リソース | ArgoCD Auto/Manual Sync | `otel-demo/overlays/{env}/` |

## GitOps 外の前提 (1回だけ手動)

| 項目 | 理由 |
|------|------|
| GitOps Operator Subscription の env 設定 | OLM 管理のため GitOps で管理不可 |

## ドキュメント

- [実装計画](docs/plan.md)
- [アーキテクチャ](docs/architecture.md)
- [昇格フロー](docs/promotion-flow.md)
- [デモシナリオ](docs/demo-scenario.md)
- [Tekton Pipeline](docs/pipeline.md)
