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

## 環境 URL

| 環境 | Frontend | Grafana | Jaeger |
|------|----------|---------|--------|
| dev  | https://frontend-proxy-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-dev.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
| stg  | https://frontend-proxy-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-stg.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
| prod | https://frontend-proxy-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://grafana-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com | https://jaeger-otel-demo-prod.apps.cluster-cfczk.cfczk.sandbox5461.opentlc.com |
