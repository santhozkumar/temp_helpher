#!/bin/bash
set -euo pipefail
exec   > >(tee -ia /var/log/pre-requisite-install.log)
exec  2> >(tee -ia /var/log/pre-requisite-install.log >& 2)
exec 19>> /var/log/pre-requisite-install.log


echo "Installing pre-requisites"
echo "========================"
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update
sudo apt-get update && sudo apt-get install -y bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog --no-install-recommends

echo "Disabling netplan"
echo "========================"
sudo mkdir -p /etc/netplan/backup
sudo mv /etc/netplan/*.yaml /etc/netplan/backup/
sudo apt-get purge -y netplan.io
sudo touch /etc/butt/butt-init.disabled


echo "Configuring systemd-networkd"
echo "========================"
cat > /etc/systemd/network/20-dhcp.network << EOF
[Match]
Name=en*

[Network]
DHCP=yes
[DHCP]
ClientIdentifier=mac
EOF

cat > /etc/systemd/network/20-dhcp-legacy.network << EOF
[Match]
Name=en*

[Network]
DHCP=yes
[DHCP]
ClientIdentifier=mac
EOF

sudo systemctl mask systemd-networkd-wait-online.service
systemctl enable systemd-networkd.service && systemctl enable systemd-resolved.service
systemctl restart systemd-networkd.service && systemctl restart systemd-resolved.service
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
