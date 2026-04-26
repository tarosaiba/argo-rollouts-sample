# OpenShift GitOps x OpenTelemetry Demo — Continuous Delivery Sample

OpenShift GitOps (ArgoCD) と OpenTelemetry Demo を題材にした Continuous Delivery サンプル実装。

## 概要

- **プラットフォーム**: OpenShift 4.18 + OpenShift GitOps Operator v1.14
- **環境**: dev / stg / prod の 3 面
- **マニフェスト管理**: Helm chart を `helm template` でフラット化 → Kustomize で管理
- **Progressive Delivery**: Argo Rollouts による Blue/Green デプロイ
- **Analysis**: HTTP Web チェックによる自動判定
- **Promote**: 全環境 Manual Promote

## ディレクトリ構成

```
├── bootstrap/
│   ├── namespaces.yaml           # Namespace 定義 + managed-by ラベル
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
├── scripts/
│   └── render-chart.sh           # Helm chart 再 render スクリプト
├── docs/
│   ├── plan.md                   # 実装計画 (Single Source of Truth)
│   ├── architecture.md           # 構成図・技術スタック
│   ├── promotion-flow.md         # 昇格手順
│   └── demo-scenario.md          # デモシナリオ
└── Makefile
```

## 環境別ポリシー

| 環境 | Sync | Self-heal | Rollout | Analysis | Promote |
|------|------|-----------|---------|----------|---------|
| dev  | Auto | あり      | Blue/Green | あり (Web check) | Manual |
| stg  | Auto | あり      | Blue/Green | あり (Web check) | Manual |
| prod | Manual | なし    | Blue/Green | あり (Web check) | Manual |

## 前提条件

- OpenShift 4.x クラスタ
- OpenShift GitOps Operator (インストール済み)
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
