# デモシナリオ

## シナリオ 1: 正常な変更の昇格

### ストーリー
frontend の Pod テンプレートにアノテーションを追加し、Blue/Green Rollout を発動させる。
dev → stg → prod に昇格する流れを確認する。

### 手順

1. **Pod テンプレートの変更**
   ```bash
   # rollout-frontend.yaml の Pod テンプレートにアノテーションを追加
   yq -i '.spec.template.metadata.annotations["demo.otel/release-note"] = "scenario-1-test"' \
     otel-demo/base/patches/rollout-frontend.yaml
   git add otel-demo/base/patches/rollout-frontend.yaml
   git commit -m "feat: add release annotation to frontend"
   git push
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
   oc patch rollout.argoproj.io frontend -n otel-demo-dev \
     --type merge --subresource status \
     -p '{"status":{"promoteFull":true}}'
   ```

3. **stg での確認**
   ```bash
   oc get rollout.argoproj.io frontend -n otel-demo-stg

   # Promote
   oc patch rollout.argoproj.io frontend -n otel-demo-stg \
     --type merge --subresource status \
     -p '{"status":{"promoteFull":true}}'
   ```

4. **prod への反映**
   ```bash
   # Manual Sync
   oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
     --type merge \
     -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'

   oc get rollout.argoproj.io frontend -n otel-demo-prod

   # Promote
   oc patch rollout.argoproj.io frontend -n otel-demo-prod \
     --type merge --subresource status \
     -p '{"status":{"promoteFull":true}}'
   ```

5. **クリーンアップ**
   ```bash
   # テスト用アノテーションを削除
   yq -i 'del(.spec.template.metadata.annotations["demo.otel/release-note"])' \
     otel-demo/base/patches/rollout-frontend.yaml
   git add otel-demo/base/patches/rollout-frontend.yaml
   git commit -m "chore: remove test annotation"
   git push
   # 各環境で再度 Promote が必要
   ```

### 確認ポイント
- ArgoCD UI でアプリケーション状態が Synced → Healthy に遷移
- Rollout が Blue/Green で preview → active に切り替わる
- Route 経由でアプリケーションにアクセスできる

---

## シナリオ 2: Analysis 失敗で Rollout 停止

### ストーリー
frontend のコンテナポートを変更し、AnalysisTemplate の HTTP チェック（ポート 8080）が
接続失敗して Rollout が自動停止する様子を確認する。

> **なぜポート変更？**
> 存在しないイメージタグ（例: `broken-tag`）を使うと ImagePullBackOff で Pod が起動せず、
> AnalysisRun の Web チェックが「実行→失敗」ではなく「タイムアウト」になる。
> ポートを変更すると Pod は正常に起動するが、AnalysisTemplate が期待する 8080 ポートで
> 応答しなくなるため、HTTP チェックが明確に失敗する。

### 手順

1. **コンテナポートを変更**
   ```bash
   # frontend のコンテナポートを 8080 → 9999 に変更
   # (Pod は起動するが、Service 経由のヘルスチェックが失敗する)
   yq -i '(.spec.template.spec.containers[] | select(.name == "frontend") | .ports[] | select(.name == "service")).containerPort = 9999' \
     otel-demo/base/patches/rollout-frontend.yaml
   yq -i '(.spec.template.spec.containers[] | select(.name == "frontend") | .env[] | select(.name == "FRONTEND_PORT")).value = "9999"' \
     otel-demo/base/patches/rollout-frontend.yaml
   git add otel-demo/base/patches/rollout-frontend.yaml
   git commit -m "test: break frontend port for analysis failure demo"
   git push
   ```

2. **dev での確認**
   ```bash
   # Rollout 状態確認 — preview pod が起動するが Analysis が失敗
   oc get rollout.argoproj.io frontend -n otel-demo-dev

   # AnalysisRun が Failed になる
   oc get analysisrun -n otel-demo-dev --sort-by=.metadata.creationTimestamp | tail -3

   # preview pod は Running だが、ポート 8080 で応答しない
   oc get pods -n otel-demo-dev -l opentelemetry.io/name=frontend
   ```

3. **Revert**
   ```bash
   # Git revert で元に戻す
   git revert HEAD
   git push
   ```

4. **復旧確認**
   ```bash
   # ArgoCD が Auto Sync で正しいマニフェストを反映
   oc get rollout.argoproj.io frontend -n otel-demo-dev

   # revert 後の Rollout 状態確認
   # revert で Pod テンプレートが active と同一に戻るため、
   # 新たな Analysis なしで直接 Healthy に遷移する
   oc get analysisrun -n otel-demo-dev --sort-by=.metadata.creationTimestamp | tail -3
   ```

### 確認ポイント
- preview Pod は Running 状態だが、ポート 8080 で応答しない
- AnalysisRun の web-check が Error になっていること（`connection refused`）
- Rollout が Degraded になり、active Service は旧バージョンのまま（ユーザー影響なし）
- Git revert 後、Pod テンプレートが active と同一に戻るため Promote 不要で Healthy に復帰

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

   # Promote
   oc patch rollout.argoproj.io frontend -n otel-demo-prod \
     --type merge --subresource status \
     -p '{"status":{"promoteFull":true}}'
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
   oc patch rollout.argoproj.io frontend -n otel-demo-dev \
     --type merge --subresource status \
     -p '{"status":{"promoteFull":true}}'
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
