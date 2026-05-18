#!/usr/bin/env bash
# 02-k3s.sh — Install k3s (Kubernetes) and Helm
# Runs as root during Packer provisioning.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.32.4+k3s1}"
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.2}"

echo "==> [02-k3s] Installing k3s ${K3S_VERSION}"

# Install k3s with Traefik disabled — we use nginx ingress for consistency
# with the local dev environment.
INSTALL_K3S_VERSION="${K3S_VERSION}" \
INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --kube-apiserver-arg=service-node-port-range=80-32767" \
  curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be healthy
echo "==> [02-k3s] Waiting for k3s to be ready"
timeout 120 bash -c 'until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 5; echo "  waiting..."; done'

echo "==> [02-k3s] Installing Helm ${HELM_VERSION}"
curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz \
  | tar -xz -C /usr/local/bin --strip-components=1 linux-amd64/helm
chmod +x /usr/local/bin/helm

echo "==> [02-k3s] Installing nginx ingress controller ${INGRESS_NGINX_VERSION}"
KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "$(echo ${INGRESS_NGINX_VERSION} | sed 's/controller-v//')" \
  --set controller.hostNetwork=true \
  --set controller.kind=DaemonSet \
  --set controller.service.type=ClusterIP \
  --set controller.service.externalTrafficPolicy="" \
  --wait --timeout 5m

echo "==> [02-k3s] Pre-pulling container images (for air-gap operation)"

# Pre-pull into k3s containerd so the appliance works without internet
IMAGES=(
  "docker.io/postgres:17-alpine"
  "docker.io/minio/minio:RELEASE.2025-04-22T22-12-26Z"
  "docker.io/minio/mc:RELEASE.2025-04-16T18-13-26Z"
)

for img in "${IMAGES[@]}"; do
  echo "  pulling ${img}"
  k3s ctr images pull "${img}"
done

# App image tag is set at build time
APP_IMAGE="${APP_IMAGE:-ghcr.io/txdmc/pelico:latest}"
echo "  pulling ${APP_IMAGE}"
k3s ctr images pull "${APP_IMAGE}"

echo "==> [02-k3s] Enabling k3s to start on boot"
systemctl enable k3s

echo "==> [02-k3s] Done"
