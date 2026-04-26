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

- [ ] `oc version` で OpenShift バージョン確認
- [ ] `oc get csv -A | grep -i gitops` で OpenShift GitOps Operator バージョン確認
- [ ] `oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml` で User Workload Monitoring 有効化状態を確認
- [ ] `oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'` で apps ドメイン確認
- [ ] `oc get crd rollouts.argoproj.io` で Argo Rollouts 導入状態確認
- [ ] 結果を表にまとめて報告し、Phase 1 で対応が必要な項目を整理

### Phase 1: 基盤準備

- [ ] User Workload Monitoring 未有効なら有効化(`cluster-monitoring-config` ConfigMap 編集)
- [ ] Argo Rollouts 未導入なら Operator 経由で導入
- [ ] 3つの Project 作成(`otel-demo-dev` / `otel-demo-stg` / `otel-demo-prod`)
- [ ] 各 Project に `argocd.argoproj.io/managed-by` ラベル付与
- [ ] Git リポジトリ作成(ユーザーが GitHub 上で作成、Claude Code は clone)
- [ ] ディレクトリスケルトン作成
- [ ] README 初版作成

### Phase 2: Helm chart のフラット化

- [ ] `scripts/render-chart.sh` 作成(`open-telemetry/opentelemetry-demo` を `helm template`)
- [ ] chart バージョンを固定して render 実行
- [ ] 結果を `otel-demo/base/manifests/` にコミット
- [ ] `base/kustomization.yaml` 作成(全 manifest を resources に列挙)
- [ ] OpenShift 共通 patch 作成(`base/patches/`)
  - Ingress → Route 置換
  - `securityContext` の固定 UID 削除
  - 必要なら ServiceAccount 調整
- [ ] `kustomize build` で render 結果を確認

### Phase 3: dev 環境構築 + 動作確認

- [ ] `overlays/dev/` 作成
  - `kustomization.yaml`(base 参照)
  - replica 数 / resource / ログレベルの dev 向け patch
- [ ] `argocd/projects/dev-project.yaml` 作成(AppProject)
- [ ] `argocd/applications/otel-demo-dev.yaml` 作成(単発 Application、Auto Sync)
- [ ] `oc apply` で AppProject + Application 投入
- [ ] Sync 実行 → 全 Pod Ready 確認
- [ ] frontend-proxy の Route から OTel Demo の Web UI アクセス確認
- [ ] Jaeger / Grafana への Route 確認
- [ ] 問題があれば patch 修正 → コミット → Sync

### Phase 4: Argo Rollouts 化(frontend を Blue/Green)

- [ ] frontend Deployment を Rollout に変換する patch を `base/patches/` に追加
  - `kind: Deployment` → `kind: Rollout`
  - `spec.strategy` を `blueGreen` に変更
  - `activeService` / `previewService` 指定
- [ ] `frontend-active` / `frontend-preview` Service を base に追加
- [ ] AnalysisTemplate 作成(成功率ベース、Prometheus query)
  - OpenShift Monitoring の `thanos-querier` を参照
  - `prePromotionAnalysis` として Rollout に組み込み
- [ ] AnalysisTemplate 用の RBAC 設定(Rollouts SA が Prometheus 参照可能に)
- [ ] dev で Rollout 動作確認
  - `kubectl-argo-rollouts` プラグインで状態確認
  - イメージタグ変更 → preview 起動 → Analysis → 手動 promote の流れ確認

### Phase 5: stg / prod overlay と ApplicationSet

- [ ] `overlays/stg/` 作成(replica 数増、ログレベル INFO)
- [ ] `overlays/prod/` 作成(replica 数最大、ログレベル WARN、resource 拡張)
- [ ] `argocd/projects/` に stg / prod の AppProject 追加
- [ ] `argocd/applicationsets/otel-demo.yaml` 作成
  - List Generator で 3環境を展開
  - 環境別の syncPolicy 切り替え(dev/stg=Auto、prod=Manual)
- [ ] `oc apply` で ApplicationSet 投入
- [ ] stg / prod に Sync(prod は手動)
- [ ] 各環境で Rollout 動作確認

### Phase 6: 昇格フロー & デモシナリオ整備

- [ ] `docs/promotion-flow.md` 作成
  - dev → stg → prod の PR ベース昇格手順
  - ロールバック手順(Rollout abort / Git revert)
- [ ] `docs/demo-scenario.md` 作成
  - シナリオ1: 正常な変更が3環境を昇格していく流れ
  - シナリオ2: Analysis 失敗で Rollout が止まる流れ
  - シナリオ3: 障害発生時のロールバック
- [ ] `docs/architecture.md` 作成(構成図、リソース関係図)
- [ ] Makefile 整備(`render-chart` / `apply-bootstrap` / `sync-all` 等)
- [ ] README をデモ実行可能なレベルに更新

### Phase 7(任意): App of Apps への昇華

- [ ] `bootstrap/root-app.yaml` 作成
  - `argocd/projects/*` と `argocd/applicationsets/*` を一括管理
- [ ] 単一 `oc apply` でクラスタ全体が再現できることを確認

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
