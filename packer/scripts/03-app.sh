#!/usr/bin/env bash
# 03-app.sh — Stage the Crate Helm chart and appliance values on disk.
# The chart is NOT deployed here; deployment happens on first boot via
# crate-firstrun.service so that passwords are unique per appliance instance.
# The app image is pulled at first-boot (latest) — not baked into the image.
set -euo pipefail

echo "==> [03-app] Staging Helm chart to /opt/crate/chart"
mkdir -p /opt/crate/chart
cp -r /tmp/crate-charts/crate/. /opt/crate/chart/

echo "==> [03-app] Done"
