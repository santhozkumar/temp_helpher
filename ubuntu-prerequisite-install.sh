sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get update
sudo apt-get update && sudo apt-get install -y bash jq zstd rsync systemd-timesyncd conntrack iptables rsyslog --no-install-recommends
sudo mkdir -p /etc/netplan/backup

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

sudo mv /etc/netplan/*.yaml /etc/netplan/backup/
sudo systemctl mask systemd-networkd-wait-online.service
systemctl enable systemd-networkd.service && systemctl enable systemd-resolved.service
systemctl restart systemd-networkd.service && systemctl restart systemd-resolved.service
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
