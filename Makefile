.PHONY: render-chart apply-bootstrap apply-projects apply-appset sync-prod setup-scc

# Helm chart を再 render
render-chart:
	./scripts/render-chart.sh

# AppProject を適用
apply-projects:
	oc apply -f argocd/projects/

# ApplicationSet + prod Application を適用
apply-appset:
	oc apply -f argocd/applicationsets/otel-demo.yaml
	oc apply -f argocd/applications/otel-demo-prod.yaml

# Bootstrap: App of Apps を適用
apply-bootstrap:
	oc apply -f bootstrap/root-app.yaml

# prod の Manual Sync をトリガー
sync-prod:
	oc patch application.argoproj.io otel-demo-prod -n openshift-gitops \
		--type merge \
		-p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'

# 全環境の Pod 状態を確認
status:
	@echo "=== DEV ===" && oc get pods -n otel-demo-dev --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo "=== STG ===" && oc get pods -n otel-demo-stg --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo "=== PROD ===" && oc get pods -n otel-demo-prod --no-headers | grep -v Running | grep -v Completed || echo "  All Running"
	@echo ""
	@oc get application.argoproj.io -n openshift-gitops | grep otel

# anyuid SCC をセットアップ
setup-scc:
	@for ns in otel-demo-dev otel-demo-stg otel-demo-prod; do \
		for sa in otel-demo grafana jaeger prometheus; do \
			oc adm policy add-scc-to-user anyuid -z $$sa -n $$ns; \
		done; \
	done

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
