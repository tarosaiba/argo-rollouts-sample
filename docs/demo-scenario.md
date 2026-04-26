# デモシナリオ

## シナリオ 1: 正常な変更の昇格

### ストーリー
frontend のイメージタグを更新し、dev → stg → prod に昇格する。

### 手順

1. **イメージタグ変更**
   ```bash
   # rollout-frontend.yaml のイメージタグを変更
   sed -i 's/2.2.0-frontend/2.2.0-frontend/' otel-demo/base/patches/rollout-frontend.yaml
   git add -A && git commit -m "feat: update frontend" && git push
   ```

2. **dev での確認**
   ```bash
   # ArgoCD が Auto Sync
   oc get application.argoproj.io otel-demo-dev -n openshift-gitops

   # Rollout 状態確認 — preview pod が起動
   oc get rollout.argoproj.io frontend -n otel-demo-dev

   # AnalysisRun の結果確認
   oc get analysisrun -n otel-demo-dev

   # 手動 Promote
   oc argo rollouts promote frontend -n otel-demo-dev
   ```

3. **stg での確認**
   ```bash
   oc get rollout.argoproj.io frontend -n otel-demo-stg
   oc argo rollouts promote frontend -n otel-demo-stg
   ```

4. **prod への反映**
   ```bash
   # Manual Sync
   oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
     --type merge \
     -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'

   oc get rollout.argoproj.io frontend -n otel-demo-prod
   oc argo rollouts promote frontend -n otel-demo-prod
   ```

### 確認ポイント
- ArgoCD UI でアプリケーション状態が Synced → Healthy に遷移
- Rollout が Blue/Green で preview → active に切り替わる
- Route 経由でアプリケーションにアクセスできる

---

## シナリオ 2: Analysis 失敗で Rollout 停止

### ストーリー
壊れたイメージをデプロイし、AnalysisTemplate の Web チェックが失敗して Rollout が自動停止する。

### 手順

1. **壊れたイメージに変更**
   ```bash
   # 存在しないタグに変更
   sed -i 's|ghcr.io/open-telemetry/demo:2.2.0-frontend|ghcr.io/open-telemetry/demo:broken-tag|' \
     otel-demo/base/patches/rollout-frontend.yaml
   git add -A && git commit -m "test: deploy broken image" && git push
   ```

2. **dev での確認**
   ```bash
   # Rollout が Paused 状態になる
   oc get rollout.argoproj.io frontend -n otel-demo-dev

   # AnalysisRun が Failed になる
   oc get analysisrun -n otel-demo-dev -l rollouts-pod-template-hash

   # preview pod が Error/CrashLoopBackOff
   oc get pods -n otel-demo-dev -l opentelemetry.io/name=frontend
   ```

3. **Abort & Revert**
   ```bash
   # Rollout を中止
   oc argo rollouts abort frontend -n otel-demo-dev

   # Git revert
   git revert HEAD && git push
   ```

### 確認ポイント
- AnalysisRun が Failed になっていること
- active Service は旧バージョンのまま（ユーザー影響なし）
- Rollout abort 後に stable revision に戻る

---

## シナリオ 3: 障害発生時のロールバック

### ストーリー
prod で問題が発見され、前のバージョンにロールバックする。

### 手順

1. **問題の検知**
   ```bash
   # Route 経由でエラー確認
   curl -sk https://frontend-proxy-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com/

   # Pod の状態確認
   oc get pods -n otel-demo-prod -l opentelemetry.io/name=frontend
   ```

2. **Git Revert でロールバック**
   ```bash
   git revert HEAD
   git push origin main
   ```

3. **prod Manual Sync**
   ```bash
   oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
     --type merge \
     -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
   ```

4. **確認**
   ```bash
   oc get rollout.argoproj.io frontend -n otel-demo-prod
   oc argo rollouts promote frontend -n otel-demo-prod
   ```

### 確認ポイント
- Git revert により全環境で元のイメージに戻る
- dev/stg は Auto Sync で自動反映
- prod は Manual Sync で明示的に反映

---

## シナリオ 4: Tekton Pipeline による段階的リリース

### ストーリー
Tekton Pipeline を使い、Wave 方式で依存関係を考慮した段階的リリースを実行する。
product-catalog + currency (Wave 1, 並列) → cart (Wave 2) → frontend (Wave 3) の順に、
イメージタグ更新 → Git push → ArgoCD Sync → Healthy 待機を自動化する。

### 前提条件
- Phase 8a のセットアップが完了していること（詳細は [docs/pipeline.md](pipeline.md) 参照）
- dev 環境が Synced & Healthy であること

### 手順

1. **現在のイメージタグを確認**
   ```bash
   oc get deployment product-catalog currency cart -n otel-demo-dev \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
   oc get rollout frontend -n otel-demo-dev \
     -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

2. **Pipeline 実行**
   ```bash
   tkn pipeline start progressive-release \
     -p image-tag=<新バージョン> \
     -w name=shared-workspace,volumeClaimTemplateFile=<(cat <<'EOF'
   spec:
     accessModes: ["ReadWriteOnce"]
     resources:
       requests:
         storage: 256Mi
   EOF
   ) \
     -w name=git-credentials,secret=git-credentials \
     --serviceaccount pipeline-sa \
     -n otel-demo-ci \
     --use-param-defaults
   ```

3. **Wave 実行状況の追跡**
   ```bash
   # ログをリアルタイムで追跡
   tkn pipelinerun logs <pipelinerun-name> -f -n otel-demo-ci

   # TaskRun ごとの状態確認
   oc get taskrun -n otel-demo-ci \
     -l tekton.dev/pipelineRun=<pipelinerun-name> \
     -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[0].reason,START:.status.startTime' \
     --sort-by=.status.startTime
   ```

4. **frontend の Rollout Promote**

   frontend は Blue/Green + Manual Promote のため、Pipeline の argocd wait がタイムアウトする前に promote が必要:
   ```bash
   # AnalysisRun の結果を確認
   oc get analysisrun -n otel-demo-dev --sort-by=.metadata.creationTimestamp | tail -1

   # promote 実行
   oc argo rollouts promote frontend -n otel-demo-dev
   ```

5. **完了確認**
   ```bash
   # Pipeline が Succeeded であること
   tkn pipelinerun describe <pipelinerun-name> -n otel-demo-ci

   # 全コンポーネントが新タグで Running
   oc get deployment product-catalog currency cart -n otel-demo-dev \
     -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
   ```

### 確認ポイント
- Wave 1 の 2 タスクが同時刻に開始されていること（並列実行）
- Wave 2 が Wave 1 完了後に開始されること
- Wave 3 が Wave 2 完了後に開始されること
- Pipeline 完了後、dev の全対象コンポーネントが新タグで Healthy

### 異常系の確認

存在しないタグで Pipeline を実行し、失敗動作を確認する:

```bash
tkn pipeline start progressive-release \
  -p image-tag=does-not-exist \
  -w name=shared-workspace,volumeClaimTemplateFile=<(cat <<'EOF'
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 256Mi
EOF
) \
  -w name=git-credentials,secret=git-credentials \
  --serviceaccount pipeline-sa \
  -n otel-demo-ci \
  --use-param-defaults
```

確認ポイント:
- Wave 1 の TaskRun が Failed になること（argocd wait タイムアウト）
- Wave 2/3 が Skipped になること
- dev の既存 Pod は旧イメージのまま Running を維持すること
- Pipeline 失敗後、dev overlay の `images` セクションを修正して復旧する（[トラブルシューティング](pipeline.md#pipeline-失敗後の-dev-環境復旧) 参照）

---

## 環境 URL

| 環境 | Frontend | Grafana | Jaeger |
|------|----------|---------|--------|
| dev  | https://frontend-proxy-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
| stg  | https://frontend-proxy-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
| prod | https://frontend-proxy-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
