# アーキテクチャ

## 全体構成

```
┌─────────────────────────────────────────────────────────────┐
│                      GitHub Repository                       │
│  ┌──────────┐  ┌──────────────────────────────────────────┐  │
│  │ argocd/  │  │ otel-demo/                               │  │
│  │ ├ projects│  │ ├ base/                                  │  │
│  │ ├ appsets │  │ │ ├ manifests/  (helm template output)   │  │
│  │ └ apps   │  │ │ ├ patches/    (Rollout, Route, etc.)   │  │
│  │          │  │ │ └ kustomization.yaml                   │  │
│  │          │  │ └ overlays/                               │  │
│  │          │  │   ├ dev/                                  │  │
│  │          │  │   ├ stg/                                  │  │
│  │          │  │   └ prod/                                 │  │
│  └──────────┘  └──────────────────────────────────────────┘  │
└─────────────────────┬───────────────────────────────────────┘
                      │ Git Webhook / Polling
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              OpenShift GitOps (ArgoCD)                        │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ ApplicationSet: otel-demo                                │ │
│  │  ├ otel-demo-dev  (Auto Sync, Self-Heal)                │ │
│  │  └ otel-demo-stg  (Auto Sync)                           │ │
│  │                                                          │ │
│  │ Application: otel-demo-prod (Manual Sync)                │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────┬──────────────┬──────────────────┬────────────────────┘
       ▼              ▼                  ▼
┌──────────┐  ┌──────────────┐  ┌───────────────┐
│otel-demo │  │ otel-demo    │  │ otel-demo     │
│   -dev   │  │    -stg      │  │    -prod      │
│          │  │              │  │               │
│ Rollout  │  │  Rollout     │  │  Rollout      │
│ (B/G)    │  │  (B/G)       │  │  (B/G)        │
│          │  │              │  │               │
│ Analysis │  │  Analysis    │  │  Analysis     │
│ Template │  │  Template    │  │  Template     │
└──────────┘  └──────────────┘  └───────────────┘
```

## リソース関係図

```
                    ┌──────────────┐
                    │ Rollout      │
                    │ (frontend)   │
                    └──────┬───────┘
                           │ manages
              ┌────────────┼────────────┐
              ▼            │            ▼
    ┌──────────────┐       │   ┌────────────────┐
    │ ReplicaSet   │       │   │ ReplicaSet     │
    │ (active)     │       │   │ (preview)      │
    └──────┬───────┘       │   └────────┬───────┘
           │               │            │
           ▼               │            ▼
    ┌──────────────┐       │   ┌────────────────┐
    │ Service      │       │   │ Service        │
    │ (frontend)   │◄──────┘   │ (frontend-     │
    │ active       │           │  preview)      │
    └──────┬───────┘           └────────────────┘
           │
           ▼
    ┌──────────────┐
    │ Service      │
    │ (frontend-   │
    │  proxy)      │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │ Route        │
    │ (frontend-   │
    │  proxy)      │──→ External Access
    └──────────────┘

    ┌──────────────────┐
    │ AnalysisTemplate │
    │ (http-success-   │
    │  rate)           │
    │ Web check on     │
    │ frontend-preview │
    └──────────────────┘
```

## 技術スタック

| コンポーネント | 技術 | バージョン |
|--------------|------|----------|
| プラットフォーム | OpenShift | 4.18.21 |
| GitOps | OpenShift GitOps (ArgoCD) | 1.14.4 |
| Progressive Delivery | Argo Rollouts | via GitOps Operator |
| マニフェスト管理 | Kustomize | v5.7.1 (oc 内蔵) |
| Chart ソース | OpenTelemetry Demo Helm | 0.40.7 |
| アプリケーション | OpenTelemetry Demo | 2.2.0 |

## SCC (SecurityContextConstraints)

コミュニティイメージは固定 UID で動作するため、`anyuid` SCC を各環境の ServiceAccount に付与:

```bash
for ns in otel-demo-dev otel-demo-stg otel-demo-prod; do
  for sa in otel-demo grafana jaeger prometheus; do
    oc adm policy add-scc-to-user anyuid -z $sa -n $ns
  done
done
```
