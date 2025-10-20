#! /bin/bash
set -euo pipefail
exec   > >(tee -ia /var/log/pre_requisite_install.log)
exec  2> >(tee -ia /var/log/pre_requisite_install.log >& 2)
exec 19>> /var/log/pre_requisite_install.log

enable_rsync_full_access() {
  # 1. Enable SELinux to allow full rsync access
  sudo setsebool -P rsync_full_access 1
  # 2. Install necessary tools for SELinux policy modules
  sudo dnf install selinux-policy-devel audit -y
  # 3. Create the SELinux policy file
  sudo tee /tmp/rsync_dac_override.te > /dev/null << 'EOF'
module rsync_dac_override 1.0;
require {
  type rsync_t;
  type default_t;
  class dir read;
  class capability dac_override;
}
# Allow rsync_t to read directories labeled default_t
allow rsync_t default_t:dir read;
# Allow rsync_t to override discretionary access control (DAC)
allow rsync_t self:capability dac_override;
EOF
  
  # 4. Compile and package the SELinux policy module
  cd /tmp
  sudo checkmodule -M -m --output rsync_dac_override.mod rsync_dac_override.te
  sudo semodule_package --outfile rsync_dac_override.pp -m rsync_dac_override.mod
  
  # 5. Install the compiled policy module
  sudo semodule --install rsync_dac_override.pp

  cd - 
  }


verify_cgroup_v2() {
  cgroup_type=$(stat -fc %T /sys/fs/cgroup)
  if [ "$cgroup_type" != "cgroup2fs" ]; then
    echo "Cgroup v2 is not enabled"
    exit 1
  fi
}

other_dependencies() {
  # required for longhorn 
  sudo dnf install -y iscsi-initiator-utils
  sudo systemctl enable --now iscsid
}

base_install() {
  sudo dnf update -y
  sudo dnf install -y bash wget jq zstd rsync conntrack-tools iptables rsyslog nfs-utils

  sudo dnf install -y systemd-resolved
  wget -O systemd-networkd.rpm https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/s/systemd-networkd-253.34-1.el9.x86_64.rpm
  wget -O systemd-timesyncd.rpm https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/s/systemd-timesyncd-253.34-1.el9.x86_64.rpm

  rpm -Uvh systemd-networkd.rpm 
  rpm -Uvh systemd-timesyncd.rpm

  sudo systemctl disable --now chronyd  || echo "chronyd not installed"
  sudo systemctl enable --now systemd-timesyncd 

  timedatectl show-timesync --all
  
  other_dependencies
}


FIPS_ENABLED="${IS_FIPS:-false}"

echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-wheel-nopasswd
if [[ "${FIPS_ENABLED}" != "true" ]]; then
  base_install
else
  echo "FIPS enable requested (IS_FIPS=true)"
  echo "====================================" 
  fips-mode-setup --enable
  echo "NOTE: Rocky9 FIPS configurations require a reboot to fully apply kernel-level changes."

  base_install
  enable_rsync_full_access
  verify_cgroup_v2
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
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
