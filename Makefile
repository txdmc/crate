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
        dev-psql dev-testdata dev-port-forward hosts helm-deps lint

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

helm-deps: ## Remove stale subchart tarballs (no external chart deps used)
	rm -f $(CHART_DIR)/charts/*.tgz $(CHART_DIR)/Chart.lock

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

dev-up: dev-build ## Build image and deploy/upgrade the Helm release
	$(KUBECTL) get namespace $(NAMESPACE) 2>/dev/null || \
	  $(KUBECTL) create namespace $(NAMESPACE)
	$(HELM) upgrade --install $(RELEASE) $(CHART_DIR) \
	  --namespace $(NAMESPACE) \
	  --values $(CHART_DIR)/values-local.yaml \
	  --wait --timeout 5m
	$(KUBECTL) rollout restart deployment/$(RELEASE) --namespace $(NAMESPACE)
	$(KUBECTL) rollout status  deployment/$(RELEASE) --namespace $(NAMESPACE) --timeout=2m
	@echo ""
	@echo "Pelico is running. Open http://pelico in your browser."

dev-down: ## Uninstall the Helm release and delete the namespace
	$(HELM) uninstall $(RELEASE) --namespace $(NAMESPACE) || true
	$(KUBECTL) delete namespace $(NAMESPACE) --ignore-not-found

dev-restart: ## Rollout restart the pelico application pods
	$(KUBECTL) rollout restart deployment/$(RELEASE) --namespace $(NAMESPACE)

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
	     --selector=app.kubernetes.io/component=postgresql,app.kubernetes.io/instance=pelico -o jsonpath='{.items[0].metadata.name}') \
	  -- psql -U pelico -d pelico

dev-testdata: ## Insert sample inventory rows into the database
	$(KUBECTL) exec --namespace $(NAMESPACE) \
	  $$($(KUBECTL) get pod --namespace $(NAMESPACE) \
	     --selector=app.kubernetes.io/component=postgresql,app.kubernetes.io/instance=pelico -o jsonpath='{.items[0].metadata.name}') \
	  -- psql -U pelico -d pelico -c "\
	INSERT INTO pelico_inventory (id, name, sku, quantity, location) VALUES \
	  ('a1b2c3d4', 'Safety Glasses',       'PPE-SG-001',  48, 'Shelf A1'), \
	  ('b2c3d4e5', 'Nitrile Gloves (L)',   'PPE-GL-L-02', 200, 'Shelf A2'), \
	  ('c3d4e5f6', 'Hard Hat (Yellow)',    'PPE-HH-003',  12, 'Cage B1'), \
	  ('d4e5f6a7', 'Fire Extinguisher',    'SAF-FE-001',   4, 'Station 1'), \
	  ('e5f6a7b8', 'Ethernet Cable 10ft',  'NET-CAT6-010', 30, 'IT Closet'), \
	  ('f6a7b8c9', 'USB-C Hub',            'NET-HUB-UC4',  3, 'IT Closet'), \
	  ('a7b8c9d0', 'Laser Printer Toner',  'PRT-TNR-HP4',  2, 'Supply Room'), \
	  ('b8c9d0e1', 'AAA Batteries (pk24)', 'ELC-BAT-AAA',  5, 'Supply Room'), \
	  ('c9d0e1f2', 'Desk Chair',           'FRN-CHR-BLK',  0, 'Warehouse'), \
	  ('d0e1f2a3', 'Standing Desk',        'FRN-DSK-STD',  7, 'Warehouse') \
	ON CONFLICT (id) DO NOTHING;" \
	&& echo "Test data inserted."

# ── Lint ──────────────────────────────────────────────────────────────────────

lint: ## Lint the Helm chart
	$(HELM) lint $(CHART_DIR) --values $(CHART_DIR)/values-local.yaml
