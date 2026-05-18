#!/usr/bin/env bash
# 03-app.sh — Stage the Pelico Helm chart and appliance values on disk.
# The chart is NOT deployed here; deployment happens on first boot via
# pelico-firstrun.service so that passwords are unique per appliance instance.
set -euo pipefail

APP_IMAGE="${APP_IMAGE:-ghcr.io/txdmc/pelico:latest}"
PELICO_VERSION="${PELICO_VERSION:-dev}"

# Split "ghcr.io/txdmc/pelico:v1.0.0" into repo and tag
APP_TAG="${APP_IMAGE##*:}"
APP_REPO="${APP_IMAGE%:*}"

echo "==> [03-app] Staging Helm chart to /opt/pelico/chart"
mkdir -p /opt/pelico/chart
cp -r /tmp/pelico-charts/pelico/. /opt/pelico/chart/

echo "==> [03-app] Substituting image placeholders in values-appliance.yaml"
# values-appliance.yaml shipped in chart has __APP_REPOSITORY__ / __APP_TAG__ placeholders
sed -i \
  -e "s|__APP_REPOSITORY__|${APP_REPO}|g" \
  -e "s|__APP_TAG__|${APP_TAG}|g" \
  /opt/pelico/chart/values-appliance.yaml

echo "==> [03-app] chart staged with image ${APP_REPO}:${APP_TAG}"
echo "==> [03-app] Done"
