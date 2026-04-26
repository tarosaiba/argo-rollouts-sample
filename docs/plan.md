# OpenShift GitOps × OpenTelemetry Demo — Continuous Delivery サンプル実装計画

## 1. 目的

OpenShift GitOps(ArgoCD)と OpenTelemetry Demo を題材に、**Continuous Delivery のプラクティス**を体系的に学習・実演できるサンプル環境を構築する。

CD の実装にフォーカスし、Secret 管理や Policy(OPA / Kyverno など)はスコープ外とする。

## 2. 確定方針

| 項目 | 内容 |
|------|------|
| プラットフォーム | OpenShift + OpenShift GitOps Operator(導入済み) |
| 環境 | dev / stg / prod の3面 |
| マニフェスト形式 | Helm chart を `helm template` でフラット化 → Kustomize で完全管理(B案) |
| Progressive Delivery | 全環境 Argo Rollouts による Blue/Green |
| Analysis | Analysis Template による自動判定あり、指標は **成功率1指標** |
| Promote 方式 | 全環境とも **Manual Promote** |
| Sync ポリシー | dev: Auto Sync / stg: Auto Sync / prod: Manual Sync |
| 昇格戦略 | ディレクトリベース(`overlays/{env}` を PR で書き換え) |
| 作業スタイル | Claude Code が `oc` で直接クラスタ操作 |
| リポジトリ | ユーザー個人の単一リポジトリ |
| スコープ外 | Secret 管理、Policy、アプリコード(OTel Demo 公式を利用) |

## 3. 環境別 Sync / Rollout ポリシー

| 環境 | Sync | Self-heal | Rollout 戦略 | Analysis | Promote |
|------|------|-----------|--------------|----------|---------|
| dev | Auto | あり | Blue/Green | あり(成功率) | Manual |
| stg | Auto | なし | Blue/Green | あり(成功率) | Manual |
| prod | Manual | なし | Blue/Green | あり(成功率) | Manual |

## 4. リポジトリ構成

```
otel-gitops-demo/
├── bootstrap/
│   └── root-app.yaml                 # App of Apps の起点(Phase 7)
├── argocd/
│   ├── projects/                     # AppProject: dev / stg / prod
│   └── applicationsets/              # 3環境を ApplicationSet で展開
├── otel-demo/
│   ├── base/
│   │   ├── manifests/                # helm template で render 済みのフラットなマニフェスト
│   │   ├── kustomization.yaml
│   │   └── patches/                  # OpenShift 共通 patch(Route, SCC, Rollout 化 等)
│   └── overlays/
│       ├── dev/                      # dev 向け patch + values 相当の差分
│       ├── stg/
│       └── prod/
├── scripts/
│   └── render-chart.sh               # Helm chart を再 render するスクリプト
├── Makefile
├── docs/
│   ├── architecture.md
│   ├── promotion-flow.md
│   └── demo-scenario.md
└── README.md
```

## 5. OpenShift 特有の考慮点

1. **SecurityContextConstraints (SCC)**: OTel Demo の一部コンポーネントは固定 UID で動こうとするため `restricted-v2` で弾かれる可能性あり。`securityContext` を空にして OpenShift 側に委譲する patch を当てる。
2. **Ingress → Route**: 公式 chart の Ingress ではなく OpenShift Route を利用。frontend-proxy 用に Route を追加。
3. **Namespace(Project)**: `argocd.argoproj.io/managed-by` ラベルを付与して ArgoCD の管理対象に。
4. **OpenShift GitOps**: `openshift-gitops` namespace のデフォルトインスタンスを利用。
5. **User Workload Monitoring**: Analysis Template から Prometheus を参照するため有効化必須。

## 6. Analysis Template の指標

OpenShift Monitoring(`thanos-querier`)を参照し、**HTTP 成功率 1 指標**で判定する。

- メトリクス: HTTP 5xx 比率(`http_server_request_duration_seconds_count` を status_code でフィルタ)
- 判定: 成功率が一定閾値を下回った場合に Rollout を失敗とする
- prePromotionAnalysis として Blue/Green の Promote 前に評価

詳細クエリと閾値は Phase 4 で具体化する。

## 7. Phase 別タスクリスト

### Phase 0: 事前情報収集(変更操作なし)

- [x] `oc version` で OpenShift バージョン確認
- [x] `oc get csv -A | grep -i gitops` で OpenShift GitOps Operator バージョン確認
- [x] `oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml` で User Workload Monitoring 有効化状態を確認
- [x] `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'` で apps ドメイン確認
- [x] `oc get crd rollouts.argoproj.io` で Argo Rollouts 導入状態確認
- [x] 結果を表にまとめて報告し、Phase 1 で対応が必要な項目を整理

### Phase 1: 基盤準備

- [x] User Workload Monitoring 未有効なら有効化 → 既に有効化済み
- [x] Argo Rollouts 未導入なら Operator 経由で導入 → CRD 導入済み、RolloutManager 作成
- [x] 3つの Project 作成(`otel-demo-dev` / `otel-demo-stg` / `otel-demo-prod`)
- [x] 各 Project に `argocd.argoproj.io/managed-by` ラベル付与
- [x] Git リポジトリ作成(ユーザーが GitHub 上で作成、Claude Code は clone)
- [x] ディレクトリスケルトン作成
- [x] README 初版作成

### Phase 2: Helm chart のフラット化

- [x] `scripts/render-chart.sh` 作成(`open-telemetry/opentelemetry-demo` を `helm template`)
- [x] chart バージョンを固定して render 実行 (v0.40.7)
- [x] 結果を `otel-demo/base/manifests/` にコミット (86ファイル)
- [x] `base/kustomization.yaml` 作成(全 manifest を resources に列挙)
- [x] OpenShift 共通 patch 作成(`base/patches/`)
  - Route 追加 (frontend-proxy, grafana, jaeger)
  - `anyuid` SCC 付与(コミュニティイメージの固定 UID 維持)
  - Prometheus メモリ増量 (400Mi → 1Gi)
- [x] `kustomize build` で render 結果を確認

### Phase 3: dev 環境構築 + 動作確認

- [x] `overlays/dev/` 作成
  - `kustomization.yaml`（base 参照、namespace: otel-demo-dev）
- [x] `argocd/projects/dev-project.yaml` 作成(AppProject)
- [x] `argocd/applications/otel-demo-dev.yaml` 作成 → ApplicationSet に統合
- [x] `oc apply` で AppProject + Application 投入
- [x] Sync 実行 → 全 Pod Ready 確認
- [x] frontend-proxy の Route から OTel Demo の Web UI アクセス確認 (HTTP 200)
- [x] Jaeger / Grafana への Route 確認 (HTTP 200/301)
- [x] 問題があれば patch 修正 → コミット → Sync

### Phase 4: Argo Rollouts 化(frontend を Blue/Green)

- [x] frontend Deployment を Rollout に変換 (`base/patches/rollout-frontend.yaml`)
  - `kind: Rollout` + `strategy.blueGreen`
  - `activeService: frontend` / `previewService: frontend-preview`
- [x] `frontend-preview` Service を base に追加
- [x] AnalysisTemplate 作成 (HTTP Web チェック)
  - preview Service への HTTP GET で成功判定
  - `prePromotionAnalysis` として Rollout に組み込み
- [x] RolloutManager 作成 (argo-rollouts namespace)
- [x] dev で Rollout 動作確認 — revision 1 完了、active/preview 切り替え成功

### Phase 5: stg / prod overlay と ApplicationSet

- [x] `overlays/stg/` 作成
- [x] `overlays/prod/` 作成
- [x] `argocd/projects/` に stg / prod の AppProject 追加
- [x] `argocd/applicationsets/otel-demo.yaml` 作成
  - List Generator で dev/stg を Auto Sync で展開
- [x] `argocd/applications/otel-demo-prod.yaml` (Manual Sync) 作成
- [x] `oc apply` で ApplicationSet + prod Application 投入
- [x] stg / prod に Sync → 全 Pod Running 確認
- [x] 各環境で Rollout 動作確認 — 全3環境で frontend Rollout Available

### Phase 6: 昇格フロー & デモシナリオ整備

- [x] `docs/promotion-flow.md` 作成
- [x] `docs/demo-scenario.md` 作成 (3シナリオ)
- [x] `docs/architecture.md` 作成(構成図、リソース関係図)
- [x] Makefile 整備 (render-chart, apply-*, status, rollout-status, routes)
- [x] README 作成

### Phase 7(任意): App of Apps への昇華

- [x] `bootstrap/root-app.yaml` 作成
  - `argocd/` ディレクトリを再帰的に管理
- [ ] 単一 `oc apply` でクラスタ全体が再現できることを確認 (SCC 以外)

## 8. Claude Code への最初の指示文

```
OpenShift GitOps を使った OpenTelemetry Demo の Continuous Delivery サンプル実装を進めます。
方針と全 Phase のタスクは docs/plan.md を参照してください。

まず Phase 0(事前情報収集)を実行してください:

1. `oc version` で OpenShift バージョン確認
2. `oc get csv -A | grep -i gitops` で OpenShift GitOps Operator バージョン確認
3. `oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml` で
   User Workload Monitoring の有効化状態確認(無ければ not found でOK)
4. `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'`
   で apps ドメイン確認
5. `oc get crd rollouts.argoproj.io` で Argo Rollouts 導入状態確認

結果を表にまとめて報告し、Phase 1 で対応が必要な項目(UWM 有効化や Rollouts 導入など)を
整理してください。実際の変更操作はこのフェーズでは行わず、報告のみにしてください。
```

## 9. 参考リンク

- [OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo)
- [OpenTelemetry Demo Helm Chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-demo)
- [OpenShift GitOps Documentation](https://docs.openshift.com/gitops/)
- [Argo Rollouts](https://argoproj.github.io/argo-rollouts/)
- [Argo Rollouts — Analysis](https://argoproj.github.io/argo-rollouts/features/analysis/)
- [Argo Rollouts — OpenShift Route Traffic Routing](https://argoproj.github.io/argo-rollouts/features/traffic-management/)

## 10. 未確定事項(Phase 0 で確認)

- OpenShift バージョン
- User Workload Monitoring 有効化状態
- apps ドメイン
- Argo Rollouts 導入状態

---

**最終更新**: 2026-04-26
