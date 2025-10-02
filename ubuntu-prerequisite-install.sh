#!/bin/bash
set -euo pipefail
exec   > >(tee -ia /var/log/pre-requisite-install.log)
exec  2> >(tee -ia /var/log/pre-requisite-install.log >& 2)
exec 19>> /var/log/pre-requisite-install.log

FIPS_ENABLED="${IS_FIPS:-false}"
FIPS_TOKEN="${FIPS_TOKEN:-}"


echo "Installing pre-requisites"
echo "========================"
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update
sudo apt-get update && sudo apt-get install -y bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog --no-install-recommends

echo "Disabling netplan"
echo "========================"
sudo mkdir -p /etc/netplan/backup
sudo mv /etc/netplan/*.yaml /etc/netplan/backup/ || echo "no yaml netplan files"


echo "Configuring systemd-networkd"
echo "========================"
cat > /etc/systemd/network/20-dhcp.network << EOF
[Match]
Name=en*

[Network]
DHCP=yes
EOF

cat > /etc/systemd/network/20-dhcp-legacy.network << EOF
[Match]
Name=eth*

[Network]
DHCP=yes
EOF

sudo systemctl mask systemd-networkd-wait-online.service
systemctl enable systemd-networkd.service && systemctl enable systemd-resolved.service
systemctl restart systemd-networkd.service && systemctl restart systemd-resolved.service
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf


#############################################
# Optional: Enable FIPS using Ubuntu Pro
#############################################
if [[ "${FIPS_ENABLED}" == "true" ]]; then
  echo "FIPS enable requested (IS_FIPS=true)"
  echo "===================================="

  if [[ -z "${FIPS_TOKEN}" ]]; then
    echo "ERROR: FIPS_TOKEN is not set, but FIPS_ENABLED=true"
    exit 1
  fi

  # Create the pro attach-config via heredoc
  # NOTE: Replace YOUR_TOKEN_HERE or mount the real secret to /run/secrets/pro-attach-config
  sudo mkdir -p /run/secrets
  sudo tee /run/secrets/pro-attach-config >/dev/null << 'EOF'
token: YOUR_TOKEN_HERE
enable_services:
  - fips
EOF
  sudo chmod 600 /run/secrets/pro-attach-config

  # Install the Pro client and prereqs
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update \
    && sudo apt-get install --no-install-recommends -y ubuntu-advantage-tools ca-certificates

  # Attach and enable services as per the attach-config (will enable FIPS)
  sudo pro attach --attach-config /run/secrets/pro-attach-config

  # Upgrade and ensure openssl present (under FIPS)
  sudo apt-get upgrade -y
  sudo apt-get install -y --no-install-recommends openssl

  # Now install your base pre-requisites *after* FIPS is on
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update \
    && sudo apt-get install -y \
    bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog \
    --no-install-recommends

  # Post-install cleanup & detach
  sudo apt-get remove -y unattended-upgrades || true
  sudo apt-get clean
  sudo rm -rf /var/lib/apt/lists/*

  # Detach from Ubuntu Pro (keeps FIPS enabled on the image unless you disable it explicitly)
  sudo pro detach --assume-yes

  echo "FIPS enablement flow completed."
  echo "NOTE: Some Ubuntu FIPS configurations require a reboot to fully apply kernel-level changes."
fi
