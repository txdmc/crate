#!/usr/bin/env bash
# 01-base.sh — Base OS hardening and package installation
# Runs as root (via sudo) during Packer provisioning.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> [01-base] Updating package lists"
apt-get update -qq

echo "==> [01-base] Upgrading installed packages"
apt-get upgrade -y -qq

echo "==> [01-base] Installing runtime dependencies"
apt-get install -y -qq \
  curl \
  wget \
  git \
  unzip \
  jq \
  openssl \
  ca-certificates \
  gnupg \
  lsb-release \
  apt-transport-https \
  software-properties-common \
  open-vm-tools \
  qemu-guest-agent \
  avahi-daemon \
  avahi-utils \
  libnss-mdns \
  nss-mdns \
  chrony \
  ufw \
  logrotate \
  htop \
  net-tools \
  dnsutils

echo "==> [01-base] Configuring hostname"
hostnamectl set-hostname "${CRATE_HOSTNAME:-crate}"
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   crate crate.local
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
HOSTS

echo "==> [01-base] Configuring mDNS (Avahi)"
# Announce 'crate.local' on the local network
cat > /etc/avahi/avahi-daemon.conf << 'AVAHI'
[server]
host-name=crate
domain-name=local
browse-domains=
use-ipv4=yes
use-ipv6=no
enable-dbus=yes
allow-point-to-point=no

[wide-area]
enable-wide-area=no

[publish]
publish-addresses=yes
publish-hinfo=yes
publish-workstation=no
publish-domain=yes

[reflector]
enable-reflector=no

[rlimits]
AVAHI

# Enable mdns in NSS resolution (for .local on the appliance itself)
sed -i 's/^hosts:.*/hosts:          files mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf

systemctl enable avahi-daemon

echo "==> [01-base] Configuring firewall (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    # HTTP (Crate UI)
ufw allow 443/tcp   # HTTPS (future TLS)
ufw allow 5353/udp  # mDNS
ufw --force enable

echo "==> [01-base] Configuring chrony (NTP)"
systemctl enable chrony

echo "==> [01-base] Disabling unneeded services"
systemctl disable --now apport.service || true
systemctl disable --now snapd.service snapd.socket || true
systemctl disable --now motd-news.service || true

echo "==> [01-base] Configuring sysctl for container workloads"
cat > /etc/sysctl.d/99-crate.conf << 'SYSCTL'
# k3s / container networking
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
# Increase inotify limits for many container files
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
SYSCTL
sysctl --system

echo "==> [01-base] Done"
