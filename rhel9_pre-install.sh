#! /bin/bash
set -euo pipefail
exec   > >(tee -ia /var/log/pre_requisite_install.log)
exec  2> >(tee -ia /var/log/pre_requisite_install.log >& 2)
exec 19>> /var/log/pre_requisite_install.log

# RHEL Subscription and Repository Management
register_rhel_subscription() {
  echo "Registering RHEL subscription..."
  if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
   echo "ERROR: USERNAME and PASSWORD environment variables are required for RHEL subscription registration"
   exit 1
  fi
  if ! subscription-manager status &>/dev/null; then
   echo "System is not registered. Registering now..."
   subscription-manager register --username "$USERNAME" --password "$PASSWORD"
   if [ $? -ne 0 ]; then
    echo "Failed to register RHEL subscription"
    exit 1
   fi
   else
    echo "System is already registered."
  fi

  # list the available repositories
  echo "Available repositories:"
  subscription-manager repos --list-enabled

  dnf repolist
  echo "RHEL Subscription Registration completed successfully!"
}

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

disable_selinux() {
  sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
}

other_dependencies() {
  # required for longhorn 
  sudo dnf install -y iscsi-initiator-utils
  sudo systemctl enable --now iscsid
}

base_install() {
  echo "Updating system packages..."
  sudo dnf update -y
  
  echo "Installing base packages..."
  sudo dnf install -y bash wget jq zstd rsync conntrack-tools iptables rsyslog nfs-utils

  echo "Installing systemd components..."
  sudo dnf install -y systemd-resolved

  wget -O systemd-networkd.rpm https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/s/systemd-networkd-253.34-1.el9.x86_64.rpm
  wget -O systemd-timesyncd.rpm https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/s/systemd-timesyncd-253.34-1.el9.x86_64.rpm

  rpm -Uvh systemd-networkd.rpm 
  rpm -Uvh systemd-timesyncd.rpm

  # Disable chronyd and enable systemd-timesyncd
  sudo systemctl disable --now chronyd  || echo "chronyd not installed"
  sudo systemctl enable --now systemd-timesyncd 

  timedatectl show-timesync --all
  
  other_dependencies
}

# Main execution
FIPS_ENABLED="${IS_FIPS:-false}"

echo "Starting RHEL 9 prerequisite installation..."
echo "FIPS Enabled: ${FIPS_ENABLED}"

# Register RHEL subscription
register_rhel_subscription

# Remove Admin group after PE-7679 is resolved
sudo groupadd admin
echo '%admin ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-admin-nopasswd

# disable_selinux
echo '%wheel ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-wheel-nopasswd

if [[ "${FIPS_ENABLED}" == "true" ]]; then
  echo "FIPS enable requested (IS_FIPS=true)"
  echo "====================================" 
  fips-mode-setup --enable
  echo "NOTE: RHEL-9 FIPS configurations require a reboot to fully apply kernel-level changes."
fi

base_install
enable_rsync_full_access
verify_cgroup_v2

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

echo "RHEL 9 prerequisite installation completed successfully!"
