#version=RHEL9
# Golden image Kickstart — shared source of truth for both the Packer
# cloud-image pipeline and PXE baremetal installs.

text
lang en_US.UTF-8
keyboard us
timezone UTC --utc

url --url="http://mirror.internal.example.com/rhel9/os/x86_64"

network --bootproto=dhcp --device=link --activate --hostname=golden-image.internal

# Accounts — root login disabled, only key-based sudo user provisioned.
# Real password hash / SSH key injected at build time via secrets, not
# committed to source control.
rootpw --lock
user --name=svc-admin --groups=wheel --iscrypted --password=${ADMIN_PW_HASH}
sshkey --username=svc-admin "${ADMIN_SSH_PUBKEY}"

# ----- Security hardening baked in at install time -----
selinux --enforcing
firewall --enabled --service=ssh
authselect select sssd --force
services --enabled=auditd,firewalld,chronyd --disabled=cups,avahi-daemon,bluetooth

bootloader --location=mbr --boot-drive=sda --iscrypted --password=${BOOTLOADER_PW_HASH}

zerombr
clearpart --all --initlabel --drives=sda
autopart --type=lvm --encrypted --passphrase=${LUKS_PASSPHRASE}

reboot

%packages
@^minimal-environment
@core
aide
audit
openscap-scanner
scap-security-guide
chrony
-telnet-server
-rsh-server
-ypbind
-tftp-server
%end

# CIS-aligned post-install hardening (same logic scripts/harden.sh
# applies in the Packer path, kept here so PXE-built hosts get parity)
%post --log=/root/ks-post.log
# Enforce password quality and lockout policy
authselect enable-feature with-faillock
sed -i 's/^#MinLen.*/MinLen = 14/' /etc/security/pwquality.conf

# Disable unused filesystems/kernel modules (CIS 1.1.1.x)
for mod in cramfs freevxfs jffs2 hfs hfsplus squashfs udf; do
  echo "install $mod /bin/true" >> /etc/modprobe.d/CIS.conf
done

# Set restrictive permissions on sensitive files
chmod 000 /etc/cron.deny 2>/dev/null || true
chmod 644 /etc/passwd
chmod 000 /etc/shadow

# Enable and configure auditd rules
systemctl enable auditd
echo "-w /etc/passwd -p wa -k identity" >> /etc/audit/rules.d/audit.rules

# Enable AIDE file integrity baseline
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

echo "Golden image Kickstart post-install completed $(date)" > /root/kickstart-complete.txt
%end
