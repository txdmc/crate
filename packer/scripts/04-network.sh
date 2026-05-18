#!/usr/bin/env bash
# 04-network.sh — Configure static hostname and mDNS for pelico.local
set -euo pipefail

PELICO_HOSTNAME="${PELICO_HOSTNAME:-pelico}"

echo "==> [04-network] Setting hostname to ${PELICO_HOSTNAME}"
hostnamectl set-hostname "${PELICO_HOSTNAME}"

echo "==> [04-network] Writing netplan (DHCP, avahi-friendly)"
cat > /etc/netplan/50-pelico.yaml << YAML
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
      dhcp-identifier: mac
      optional: true
YAML
chmod 600 /etc/netplan/50-pelico.yaml

# Remove any installer-generated netplan configs to avoid conflicts
rm -f /etc/netplan/00-installer-config.yaml

echo "==> [04-network] Writing /etc/hostname-update service"
# On every boot, update /etc/hosts with the current IP so that
# 'pelico' resolves locally even before mDNS propagates.
cat > /usr/local/sbin/pelico-update-host.sh << 'SCRIPT'
#!/usr/bin/env bash
# Run on startup to keep /etc/hosts current
IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -n "$IP" ]; then
  sed -i "/pelico/d" /etc/hosts
  echo "${IP}    pelico pelico.local" >> /etc/hosts
fi
SCRIPT
chmod +x /usr/local/sbin/pelico-update-host.sh

cat > /etc/systemd/system/pelico-update-host.service << 'UNIT'
[Unit]
Description=Update /etc/hosts with current IP for pelico
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pelico-update-host.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable pelico-update-host.service

echo "==> [04-network] Enabling Avahi mDNS"
systemctl enable avahi-daemon

echo "==> [04-network] Done"
