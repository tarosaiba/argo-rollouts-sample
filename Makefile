.PHONY: render-chart setup-prereqs apply-bootstrap sync-prod status rollout-status routes

# ============================================================
# 1. 初期セットアップ (クラスタに1回だけ実行)
# ============================================================

# 前提条件: Namespace, SCC, RolloutManager を宣言的に適用
# ※ Subscription の CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES は手動対応
setup-prereqs:
	oc apply -f bootstrap/namespaces.yaml
	oc apply -f bootstrap/scc-anyuid.yaml
	oc apply -f bootstrap/rollout-manager.yaml

# App of Apps: ArgoCD が argocd/ 配下を自動管理
apply-bootstrap: setup-prereqs
	oc apply -f bootstrap/root-app.yaml

# ============================================================
# 2. 運用
# ============================================================

# Helm chart を再 render
render-chart:
	./scripts/render-chart.sh

# prod の Manual Sync をトリガー
sync-prod:
	oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
		--type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'

# ============================================================
# 3. 確認コマンド
# ============================================================

# 全環境の Pod 状態を確認
status:
	@echo "=== DEV ===" && oc get pods -n otel-demo-dev --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo "=== STG ===" && oc get pods -n otel-demo-stg --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo "=== PROD ===" && oc get pods -n otel-demo-prod --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo ""
	@oc get application.argoproj.io -n openshift-gitops | grep otel

# Rollout 状態を全環境で確認
rollout-status:
	@for ns in otel-demo-dev otel-demo-stg otel-demo-prod; do \
		echo "=== $$ns ===" && oc get rollout.argoproj.io -n $$ns 2>/dev/null || echo "  No rollouts"; \
	done

# 全環境の Route URL を表示
routes:
	@for ns in otel-demo-dev otel-demo-stg otel-demo-prod; do \
		echo "=== $$ns ===" && oc get routes -n $$ns -o custom-columns='NAME:.metadata.name,URL:.spec.host' 2>/dev/null || echo "  No routes"; \
	done
