#!/usr/bin/env bash
# harden.sh — CIS-benchmark-aligned hardening applied during the Packer
# build. Mirrors the %post section of kickstart/golden.ks so cloud
# images (Packer) and baremetal images (PXE + Kickstart) end up
# equivalently hardened.

set -euo pipefail

echo "==> Applying SSH hardening"
sed -i \
  -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
  -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
  -e 's/^#*X11Forwarding.*/X11Forwarding no/' \
  -e 's/^#*MaxAuthTries.*/MaxAuthTries 4/' \
  /etc/ssh/sshd_config

echo "==> Setting password quality policy"
sudo dnf install -y libpwquality
sed -i 's/^# minlen.*/minlen = 14/' /etc/security/pwquality.conf

echo "==> Disabling unused filesystems (CIS 1.1.1.x)"
for mod in cramfs freevxfs jffs2 hfs hfsplus squashfs udf; do
  echo "install ${mod} /bin/true" | sudo tee -a /etc/modprobe.d/CIS.conf > /dev/null
done

echo "==> Enabling and configuring auditd"
sudo systemctl enable auditd
echo "-w /etc/passwd -p wa -k identity" | sudo tee -a /etc/audit/rules.d/audit.rules > /dev/null
echo "-w /etc/group -p wa -k identity"  | sudo tee -a /etc/audit/rules.d/audit.rules > /dev/null

echo "==> Enforcing firewall default-deny with only required ports open"
sudo systemctl enable firewalld
sudo firewall-cmd --permanent --set-default-zone=drop
sudo firewall-cmd --permanent --zone=drop --add-service=ssh
sudo firewall-cmd --reload

echo "==> Removing insecure/legacy services"
for svc in telnet rsh ypserv tftp; do
  sudo dnf remove -y "${svc}*" 2>/dev/null || true
done

echo "==> Setting file permissions on sensitive files"
sudo chmod 644 /etc/passwd
sudo chmod 000 /etc/shadow
sudo chown root:root /etc/shadow

echo "==> Initializing AIDE file-integrity baseline"
sudo dnf install -y aide
sudo aide --init
sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

echo "==> Hardening complete"
