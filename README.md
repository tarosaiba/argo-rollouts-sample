# OpenShift GitOps x OpenTelemetry Demo — Continuous Delivery Sample

OpenShift GitOps (ArgoCD) と OpenTelemetry Demo を題材にした Continuous Delivery サンプル実装。

## 概要

- **プラットフォーム**: OpenShift 4.18 + OpenShift GitOps Operator v1.14
- **環境**: dev / stg / prod の 3 面
- **マニフェスト管理**: Helm chart を `helm template` でフラット化 → Kustomize で管理
- **Progressive Delivery**: Argo Rollouts による Blue/Green デプロイ
- **Analysis**: HTTP 成功率ベースの自動判定 (Prometheus / thanos-querier)
- **Promote**: 全環境 Manual Promote

## ディレクトリ構成

```
├── bootstrap/                  # App of Apps の起点
├── argocd/
│   ├── projects/               # AppProject (dev / stg / prod)
│   └── applicationsets/        # 3環境を ApplicationSet で展開
├── otel-demo/
│   ├── base/
│   │   ├── manifests/          # helm template で render 済みマニフェスト
│   │   ├── patches/            # OpenShift 共通 patch
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── dev/
│       ├── stg/
│       └── prod/
├── scripts/
│   └── render-chart.sh         # Helm chart 再 render スクリプト
├── docs/
│   └── plan.md                 # 実装計画 (Single Source of Truth)
└── Makefile
```

## 環境別ポリシー

| 環境 | Sync | Self-heal | Rollout | Analysis | Promote |
|------|------|-----------|---------|----------|---------|
| dev  | Auto | あり      | Blue/Green | あり (成功率) | Manual |
| stg  | Auto | なし      | Blue/Green | あり (成功率) | Manual |
| prod | Manual | なし    | Blue/Green | あり (成功率) | Manual |

## 前提条件

- OpenShift 4.x クラスタ
- OpenShift GitOps Operator (インストール済み)
- Argo Rollouts (CRD 導入済み)
- User Workload Monitoring 有効化済み
- `oc` / `helm` CLI

## クイックスタート

```bash
# 1. Helm chart を render
make render-chart

# 2. Bootstrap (App of Apps) を適用
make apply-bootstrap

# 3. 全環境を Sync
make sync-all
```

詳細は [docs/plan.md](docs/plan.md) を参照。
