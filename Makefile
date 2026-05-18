################################################################################
# Pelico — Developer Makefile
#
# Prerequisites (macOS):
#   brew install helm kubectl
#   Docker Desktop with Kubernetes enabled
#
# Quick start:
#   make dev-deps   # install nginx ingress controller into Docker Desktop k8s
#   make hosts      # add 'pelico' to /etc/hosts (one-time, requires sudo)
#   make dev-up     # build image + deploy chart
#   open http://pelico
################################################################################

IMAGE_NAME  := pelico/app
IMAGE_TAG   := local
CHART_DIR   := charts/pelico
NAMESPACE   := pelico
RELEASE     := pelico

KUBECTL     := kubectl
HELM        := helm

# nginx ingress-nginx controller version pinned for reproducibility
INGRESS_NGINX_VERSION := controller-v1.11.2

.PHONY: help dev-deps dev-build dev-up dev-down dev-restart dev-logs dev-status \
        dev-psql dev-port-forward hosts helm-deps lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Prerequisites ─────────────────────────────────────────────────────────────

dev-deps: ## Install nginx ingress controller into the local k8s cluster
	@echo "Installing ingress-nginx $(INGRESS_NGINX_VERSION)..."
	$(KUBECTL) apply -f \
	  https://raw.githubusercontent.com/kubernetes/ingress-nginx/$(INGRESS_NGINX_VERSION)/deploy/static/provider/cloud/deploy.yaml
	@echo "Waiting for ingress-nginx pods to be ready (up to 120s)..."
	$(KUBECTL) wait --namespace ingress-nginx \
	  --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller \
	  --timeout=120s
	@echo "Done. ingress-nginx is ready."

helm-deps: ## Fetch bitnami chart dependencies
	$(HELM) repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
	$(HELM) repo update
	$(HELM) dependency update $(CHART_DIR)

hosts: ## Add 'pelico' to /etc/hosts (requires sudo)
	@if grep -qF 'pelico' /etc/hosts; then \
	  echo "'pelico' already present in /etc/hosts — skipping"; \
	else \
	  echo "127.0.0.1  pelico" | sudo tee -a /etc/hosts; \
	  echo "Added '127.0.0.1  pelico' to /etc/hosts"; \
	fi

# ── Image ─────────────────────────────────────────────────────────────────────

dev-build: ## Build the application container image
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) application/
	@echo "Image built: $(IMAGE_NAME):$(IMAGE_TAG)"

# ── Deploy ────────────────────────────────────────────────────────────────────

dev-up: dev-build helm-deps ## Build image and deploy/upgrade the Helm release
	$(KUBECTL) get namespace $(NAMESPACE) 2>/dev/null || \
	  $(KUBECTL) create namespace $(NAMESPACE)
	$(HELM) upgrade --install $(RELEASE) $(CHART_DIR) \
	  --namespace $(NAMESPACE) \
	  --values $(CHART_DIR)/values-local.yaml \
	  --wait --timeout 5m
	@echo ""
	@echo "Pelico is running. Open http://pelico in your browser."
	@echo "(If the page doesn't load, ensure you've run 'make hosts' and 'make dev-deps'.)"

dev-down: ## Uninstall the Helm release and delete the namespace
	$(HELM) uninstall $(RELEASE) --namespace $(NAMESPACE) || true
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found

dev-restart: ## Rollout restart the pelico application pods
	$(KUBECTL) rollout restart deployment/$(RELEASE)-pelico --namespace $(NAMESPACE)

# ── Observability ─────────────────────────────────────────────────────────────

dev-logs: ## Tail application logs
	$(KUBECTL) logs --namespace $(NAMESPACE) \
	  --selector=app.kubernetes.io/name=pelico \
	  --container pelico --follow

dev-status: ## Show pod and service status in the pelico namespace
	@echo "=== Pods ==="
	$(KUBECTL) get pods --namespace $(NAMESPACE)
	@echo ""
	@echo "=== Services ==="
	$(KUBECTL) get svc --namespace $(NAMESPACE)
	@echo ""
	@echo "=== Ingress ==="
	$(KUBECTL) get ingress --namespace $(NAMESPACE)

# ── Database ──────────────────────────────────────────────────────────────────

dev-psql: ## Open a psql shell inside the postgresql pod
	$(KUBECTL) exec --namespace $(NAMESPACE) -it \
	  $$($(KUBECTL) get pod --namespace $(NAMESPACE) \
	     --selector=app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}') \
	  -- psql -U pelico -d pelico

# ── Lint ──────────────────────────────────────────────────────────────────────

lint: ## Lint the Helm chart
	$(HELM) lint $(CHART_DIR) --values $(CHART_DIR)/values-local.yaml
