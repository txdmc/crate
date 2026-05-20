#!/usr/bin/env bash
# 05-firstrun.sh — Install the crate-firstrun systemd service.
#   The SERVICE runs on first boot: pulls the latest app image, generates
#   passwords, waits for k3s, deploys the Helm chart, then never runs again.
set -euo pipefail

echo "==> [05-firstrun] Installing crate-firstrun service"

# Runtime script that actually runs on first boot
cat > /usr/local/sbin/crate-firstrun.sh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

PASSWORDS_FILE="/etc/crate/passwords.env"
CHART_DIR="/opt/crate/chart"
APP_IMAGE="ghcr.io/txdmc/crate:latest"
HELM=/usr/local/bin/helm

log() { echo "[crate-firstrun] $*"; }

log "Starting first-run initialization"

# Guard — already initialized
if [ -f "$PASSWORDS_FILE" ]; then
    log "Already initialized — skipping"
    exit 0
fi

# Wait for k3s node to become Ready (up to 3 minutes)
log "Waiting for k3s cluster to become ready..."
if ! timeout 180 bash -c '
  until kubectl get nodes 2>/dev/null | grep -qE "Ready"; do
    echo "[crate-firstrun] waiting for k3s..."
    sleep 5
  done
'; then
    log "ERROR: k3s did not become ready within 3 minutes"
    exit 1
fi
log "k3s is ready"

# Pull the latest app image — this is the step that fetches the current release
log "Pulling latest Crate application image..."
if ! k3s ctr images pull "${APP_IMAGE}"; then
    log "ERROR: Failed to pull ${APP_IMAGE}"
    log "       Ensure the appliance has internet access on first boot."
    log "       Check: curl -I https://ghcr.io"
    exit 1
fi
log "Image pulled: ${APP_IMAGE}"

# Generate secrets
mkdir -p /etc/crate
chmod 700 /etc/crate

POSTGRES_PASSWORD=$(openssl rand -hex 20)
MINIO_ACCESS_KEY="crateadmin"
MINIO_SECRET_KEY=$(openssl rand -hex 20)
APP_SECRET_KEY=$(openssl rand -hex 32)

cat > "$PASSWORDS_FILE" << ENV
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
APP_SECRET_KEY=${APP_SECRET_KEY}
ENV
chmod 600 "$PASSWORDS_FILE"
log "Unique secrets generated"

# Deploy Helm chart
log "Deploying Crate Helm chart..."
$HELM upgrade --install crate "$CHART_DIR" \
    --namespace crate \
    --create-namespace \
    --values "${CHART_DIR}/values-appliance.yaml" \
    --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
    --set minio.auth.rootPassword="${MINIO_SECRET_KEY}" \
    --set minio.auth.rootUser="${MINIO_ACCESS_KEY}" \
    --set app.secretKey="${APP_SECRET_KEY}" \
    --wait \
    --timeout 10m

log "Helm chart deployed successfully"

IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "unknown")
log "======================================================"
log "  Crate is ready!"
log "  URL:  http://crate  or  http://crate.local"
log "        http://${IP}"
log "======================================================"

SCRIPT
chmod +x /usr/local/sbin/crate-firstrun.sh

# Systemd unit
cat > /etc/systemd/system/crate-firstrun.service << 'UNIT'
[Unit]
Description=Crate First-Run Initialization
Documentation=https://github.com/txdmc/crate
After=k3s.service network-online.target
Wants=network-online.target
Requires=k3s.service
ConditionPathExists=!/etc/crate/passwords.env

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/crate-firstrun.sh
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=900
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable crate-firstrun.service

echo "==> [05-firstrun] Done"
