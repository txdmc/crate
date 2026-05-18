#!/usr/bin/env bash
# 04-network.sh — Configure static hostname and mDNS for crate.local
set -euo pipefail

CRATE_HOSTNAME="${CRATE_HOSTNAME:-crate}"

echo "==> [04-network] Setting hostname to ${CRATE_HOSTNAME}"
hostnamectl set-hostname "${CRATE_HOSTNAME}"

echo "==> [04-network] Writing netplan (DHCP, avahi-friendly)"
cat > /etc/netplan/50-crate.yaml << YAML
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
chmod 600 /etc/netplan/50-crate.yaml

# Remove any installer-generated netplan configs to avoid conflicts
rm -f /etc/netplan/00-installer-config.yaml

echo "==> [04-network] Writing /etc/hostname-update service"
# On every boot, update /etc/hosts with the current IP so that
# 'crate' resolves locally even before mDNS propagates.
cat > /usr/local/sbin/crate-update-host.sh << 'SCRIPT'
#!/usr/bin/env bash
# Run on startup to keep /etc/hosts current
IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -n "$IP" ]; then
  sed -i "/crate/d" /etc/hosts
  echo "${IP}    crate crate.local" >> /etc/hosts
fi
SCRIPT
chmod +x /usr/local/sbin/crate-update-host.sh

cat > /etc/systemd/system/crate-update-host.service << 'UNIT'
[Unit]
Description=Update /etc/hosts with current IP for crate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/crate-update-host.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable crate-update-host.service

echo "==> [04-network] Enabling Avahi mDNS"
systemctl enable avahi-daemon

echo "==> [04-network] Done"
