# 昇格フロー (Promotion Flow)

## 概要

dev → stg → prod の3環境をディレクトリベースで昇格する。
各環境は `otel-demo/overlays/{env}/` を ArgoCD Application が監視している。

## 昇格手順

### 1. dev での変更

```bash
# base/ のマニフェストを変更（例: イメージタグ更新）
vim otel-demo/base/patches/rollout-frontend.yaml

# コミット & push
git add -A && git commit -m "feat: update frontend image" && git push
```

ArgoCD Auto Sync により dev に自動反映される。
Argo Rollouts が Blue/Green デプロイを開始し、prePromotionAnalysis が実行される。

### 2. dev での Rollout 確認 & Promote

```bash
# Rollout 状態確認
oc get rollout.argoproj.io frontend -n otel-demo-dev

# Promote (手動)
oc argo rollouts promote frontend -n otel-demo-dev
# または
oc patch rollout.argoproj.io frontend -n otel-demo-dev \
  --type merge -p '{"status":{"promoteFull":true}}'
```

### 3. stg への昇格

dev で確認できたら、同じ変更が base/ に含まれているため stg にも Auto Sync される。

```bash
# stg の Rollout 状態確認
oc get rollout.argoproj.io frontend -n otel-demo-stg

# Promote
oc argo rollouts promote frontend -n otel-demo-stg
```

### 4. prod への昇格

prod は Manual Sync のため、明示的に Sync をトリガーする必要がある。

```bash
# ArgoCD UI から Manual Sync、または:
oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
  --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'

# prod の Rollout 状態確認
oc get rollout.argoproj.io frontend -n otel-demo-prod

# Promote
oc argo rollouts promote frontend -n otel-demo-prod
```

## ロールバック手順

### 方法 1: Rollout Abort

進行中の Rollout を中止し、active (旧バージョン) に戻す。

```bash
oc argo rollouts abort frontend -n otel-demo-{env}
```

### 方法 2: Git Revert

Git 上で変更を revert し、ArgoCD Auto Sync で反映。

```bash
git revert HEAD
git push origin main
```

### 方法 3: ArgoCD Rollback

ArgoCD UI または CLI で以前の revision に戻す。

## フロー図

```
[base/ 変更] → [git push] → [dev Auto Sync]
                                    ↓
                            [Rollout Blue/Green]
                                    ↓
                         [prePromotionAnalysis]
                                    ↓
                          [Manual Promote] ✓
                                    ↓
                           [stg Auto Sync]
                                    ↓
                            [Rollout Blue/Green]
                                    ↓
                          [Manual Promote] ✓
                                    ↓
                          [prod Manual Sync]
                                    ↓
                            [Rollout Blue/Green]
                                    ↓
                          [Manual Promote] ✓
```
