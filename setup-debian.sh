#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-root}"
SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIvWfTreCb3RCCDpCO2oEytXYs27/L3gW3b/gavJ0Cdn sxzcy1993@gmail.com'

NZ_SERVER="${NZ_SERVER:-agent-nezha.knowx.top:443}"
NZ_TLS="${NZ_TLS:-true}"
NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:?Please set NZ_CLIENT_SECRET before running this script}"

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0"
  exit 1
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "User does not exist: $TARGET_USER"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y \
  ca-certificates \
  curl \
  wget \
  git \
  vim \
  nano \
  sudo \
  ufw \
  htop \
  unzip \
  tar \
  chrony \
  openssh-server

# --- kernel: 显式升级内核 meta 包，避免重装后回退到含已知 CVE 的旧内核 ---
# 说明：`apt-get upgrade` 遇到需要新装包的内核更新会 kept back，
# 必须显式 install 内核 meta 包；装完需重启才生效。
KERNEL_PKG="linux-image-cloud-amd64"
if [[ "$(uname -m)" == "aarch64" ]]; then
  KERNEL_PKG="linux-image-cloud-arm64"
fi
apt-get install -y "$KERNEL_PKG" || true

systemctl enable --now chrony >/dev/null 2>&1 || true
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if ! grep -qxF "$SSH_PUBLIC_KEY" "$AUTH_KEYS"; then
  printf '%s\n' "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
fi

install -d -m 755 /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/99-key-only.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

SSHD_BIN="$(command -v sshd || true)"
if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
  SSHD_BIN="/usr/sbin/sshd"
fi

"$SSHD_BIN" -t

systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true

cd /tmp
rm -f agent.sh
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh
env NZ_SERVER="$NZ_SERVER" NZ_TLS="$NZ_TLS" NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" ./agent.sh

echo
echo "Kernel meta:  ${KERNEL_PKG}=$(dpkg-query -W -f='${Version}' "$KERNEL_PKG" 2>/dev/null || echo unknown)"
echo "Running:      $(uname -r)"
echo "上面两行不一致时，重启一次以启用新内核。"
echo
echo "Done."
echo "SSH password login is disabled. Public key login remains enabled."
echo "Keep this SSH session open and test a new login:"
echo "ssh -i ~/.ssh/id_ed25519_github ${TARGET_USER}@YOUR_VPS_IP"
echo
echo "Nezha Agent status:"
echo "systemctl status nezha-agent --no-pager"

# 可选：AUTO_REBOOT=yes 时自动重启以启用新内核
if [[ "${AUTO_REBOOT:-no}" == "yes" ]]; then
  echo
  echo "AUTO_REBOOT=yes，5 秒后重启..."
  sleep 5
  systemctl reboot
fi
