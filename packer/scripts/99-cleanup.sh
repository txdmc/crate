#!/usr/bin/env bash
# 99-cleanup.sh — Final image hardening and disk zeroing for compression.
#   Run as the LAST provisioner step inside the Packer build VM.
set -euo pipefail

echo "==> [99-cleanup] APT cleanup"
apt-get -y autoremove --purge
apt-get -y clean
rm -rf /var/lib/apt/lists/*

echo "==> [99-cleanup] Remove temporary build artifacts"
rm -f /tmp/*.sh /tmp/*.deb /tmp/*.tar.gz

echo "==> [99-cleanup] Truncate machine-id (regenerated on first boot)"
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

echo "==> [99-cleanup] Remove SSH host keys (regenerated on first boot)"
rm -f /etc/ssh/ssh_host_*
# Ensure ssh.service regenerates them on next boot
systemctl enable ssh-keygen 2>/dev/null || true

echo "==> [99-cleanup] Lock the build-time password for pelico user"
passwd -l pelico

echo "==> [99-cleanup] Clear shell histories and temp credentials"
find /root /home -name ".bash_history" -delete 2>/dev/null || true
find /root /home -name ".wget-hsts" -delete 2>/dev/null || true
find /root /home -name ".ssh/known_hosts" -delete 2>/dev/null || true

echo "==> [99-cleanup] Clearing log files"
find /var/log -type f | while read -r f; do
  echo -n > "$f" 2>/dev/null || true
done
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true

echo "==> [99-cleanup] Zero free disk space for compression"
# Write zeros to free space then delete, so xz can compress it well
dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
sync
rm -f /EMPTY
sync

echo "==> [99-cleanup] Done"
