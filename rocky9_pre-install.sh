#! /bin/bash
set -euo pipefail
exec   > >(tee -ia /var/log/pre_requisite_install.log)
exec  2> >(tee -ia /var/log/pre_requisite_install.log >& 2)
exec 19>> /var/log/pre_requisite_install.log

base_install() {
  sudo dnf update -y
  sudo dnf install -y bash jq zstd rsync conntrack-tools iptables rsyslog

  sudo dnf config-manager --set-enabled crb
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  sudo dnf install -y systemd-resolved systemd-networkd systemd-timesyncd

  sudo systemctl disable --now chronyd  || echo "chronyd not installed"
  sudo systemctl enable --now systemd-timesyncd 

  timedatectl show-timesync --all
}


FIPS_ENABLED="${IS_FIPS:-false}"

if [[ "${FIPS_ENABLED}" != "true" ]]; then
  base_install
else
  echo "FIPS enable requested (IS_FIPS=true)"
  echo "====================================" 
  fips-mode-setup --enable
  echo "NOTE: RHEL FIPS configurations require a reboot to fully apply kernel-level changes."
  base_install
fi

echo "Disabling NetworkManager"
echo "========================"
sudo systemctl stop NetworkManager.service && sudo systemctl disable NetworkManager.service || echo "NetworkManager not installed"

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
Name=eth*

[Network]
DHCP=yes
[DHCP]
ClientIdentifier=mac
EOF

sudo systemctl mask systemd-networkd-wait-online.service
systemctl enable --now systemd-networkd.service && systemctl enable --now systemd-resolved.service
# systemctl restart systemd-networkd.service && systemctl restart systemd-resolved.service
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
