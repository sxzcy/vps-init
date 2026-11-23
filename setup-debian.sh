#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-root}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIvWfTreCb3RCCDpCO2oEytXYs27/L3gW3b/gavJ0Cdn sxzcy1993@gmail.com}"
SSH_KEY_URLS="${SSH_KEY_URLS:-}"
SSH_GITHUB_USER="${SSH_GITHUB_USER:-}"

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
SWAP_SIZE="${SWAP_SIZE:-auto}"
ENABLE_BBR="${ENABLE_BBR:-yes}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-yes}"
INSTALL_DOCKER="${INSTALL_DOCKER:-no}"

INSTALL_NEZHA="${INSTALL_NEZHA:-yes}"
NZ_SERVER="${NZ_SERVER:-agent-nezha.knowx.top:443}"
NZ_TLS="${NZ_TLS:-true}"

AUTO_REBOOT="${AUTO_REBOOT:-no}"

PUBKEY_REGEX='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

if [[ "$INSTALL_NEZHA" == "yes" ]]; then
  NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:?Please set NZ_CLIENT_SECRET before running this script (or pass INSTALL_NEZHA=no to skip)}"
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "User does not exist: $TARGET_USER" >&2
  exit 1
fi

if [[ -n "$NEW_HOSTNAME" ]] && [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
  echo "Invalid NEW_HOSTNAME: $NEW_HOSTNAME" >&2
  exit 1
fi

TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || id -g "$TARGET_USER")"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  echo "Home directory not found for user ${TARGET_USER}: ${USER_HOME}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export DEBIAN_FRONTEND=noninteractive

# --- 基础更新与常用排障/运维工具 ---
apt-get update
apt-get upgrade -y \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

BASE_PACKAGES=(
  ca-certificates
  curl
  wget
  git
  vim
  nano
  sudo
  htop
  tmux
  jq
  dnsutils
  mtr-tiny
  lsof
  ncdu
  gnupg
  unzip
  tar
  tzdata
  chrony
  openssh-server
)

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
  BASE_PACKAGES+=(unattended-upgrades)
fi

apt-get install -y "${BASE_PACKAGES[@]}"

# --- kernel: 显式升级对应类型的内核 meta 包，避免重装后回退到含已知 CVE 的旧内核 ---
# 说明：`apt-get upgrade` 遇到需要新装包的内核更新会 kept back；
# 按当前运行内核自动区分 cloud 与标准内核，避免非 cloud 机型错换精简内核。
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
  amd64|x86_64) KERNEL_ARCH="amd64" ;;
  arm64|aarch64) KERNEL_ARCH="arm64" ;;
  *) KERNEL_ARCH="" ;;
esac

KERNEL_PKG=""
if [[ -n "$KERNEL_ARCH" ]]; then
  if [[ "$(uname -r)" == *-cloud-* ]] || dpkg-query -W -f='${Status}' "linux-image-cloud-${KERNEL_ARCH}" 2>/dev/null | grep -q "install ok installed"; then
    KERNEL_PKG="linux-image-cloud-${KERNEL_ARCH}"
  else
    KERNEL_PKG="linux-image-${KERNEL_ARCH}"
  fi
  if ! apt-get install -y "$KERNEL_PKG"; then
    echo "Warning: failed to install kernel meta package ${KERNEL_PKG}; continuing." >&2
  fi
else
  echo "Warning: unsupported architecture (${ARCH}); skipping kernel meta upgrade." >&2
fi

systemctl enable --now chrony >/dev/null 2>&1 || true
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

# --- 时区统一 ---
if [[ -n "$TIMEZONE" && "$TIMEZONE" != "keep" ]]; then
  if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1; then
      :
    else
      ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
      printf '%s\n' "$TIMEZONE" > /etc/timezone
    fi
  else
    echo "Warning: timezone not found: ${TIMEZONE}; skipping." >&2
  fi
fi

# --- 可选主机名设置 ---
if [[ -n "$NEW_HOSTNAME" ]]; then
  if command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$NEW_HOSTNAME" >/dev/null 2>&1; then
    :
  else
    printf '%s\n' "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME" >/dev/null 2>&1 || true
  fi
  if grep -Eq '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1 ${NEW_HOSTNAME}|" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$NEW_HOSTNAME" >> /etc/hosts
  fi
fi

# --- 限制 systemd-journald 日志体积，避免小硬盘被日志撑爆 ---
if command -v journalctl >/dev/null 2>&1; then
  install -d -m 755 /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/99-limit.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
  systemctl restart systemd-journald >/dev/null 2>&1 || true
fi

# --- 自动安全更新（仅安装安全补丁，不自动重启） ---
if [[ "$ENABLE_UNATTENDED_UPGRADES" == "yes" ]]; then
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >/etc/apt/apt.conf.d/52vps-init-unattended <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
fi

# --- 小内存 VPS 自动兜底 Swap ---
setup_swap() {
  local mode="$1"
  local desired_size=""
  local mem_mb avail_mb root_fs

  case "$mode" in
    no|none|0|"") return 0 ;;
    auto)
      if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
        return 0
      fi
      mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
      if [[ "$mem_mb" -le 0 || "$mem_mb" -gt 2048 ]]; then
        return 0
      fi
      avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
      if [[ "${avail_mb:-0}" -lt 3072 ]]; then
        echo "Info: root partition has < 3 GiB free (${avail_mb} MiB); skipping auto swapfile."
        return 0
      fi
      desired_size="1G"
      ;;
    *)
      if [[ ! "$mode" =~ ^[0-9]+[MG]$ ]]; then
        echo "Warning: invalid SWAP_SIZE (${mode}); expected auto, 0, or e.g. 1G / 512M. Skipping." >&2
        return 0
      fi
      if [[ -n "$(swapon --show --noheadings 2>/dev/null || true)" ]]; then
        echo "Info: swap already active; skipping swapfile creation."
        return 0
      fi
      desired_size="$mode"
      ;;
  esac

  if [[ -e /swapfile ]]; then
    echo "Info: /swapfile already exists; skipping swapfile creation."
    return 0
  fi

  root_fs="$(df -PT / | awk 'NR==2 {print $2}')"
  if [[ "$root_fs" == "btrfs" ]]; then
    echo "Info: root filesystem is btrfs; skipping automatic swapfile creation."
    return 0
  fi

  echo "Creating ${desired_size} swapfile at /swapfile..."
  if ! fallocate -l "$desired_size" /swapfile 2>/dev/null; then
    local count_mb
    if [[ "$desired_size" == *G ]]; then
      count_mb=$(( ${desired_size%G} * 1024 ))
    else
      count_mb="${desired_size%M}"
    fi
    if ! dd if=/dev/zero of=/swapfile bs=1M count="$count_mb" status=none; then
      rm -f /swapfile
      echo "Warning: failed to allocate /swapfile; skipping swap setup." >&2
      return 0
    fi
  fi

  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null 2>&1 || ! swapon /swapfile >/dev/null 2>&1; then
    rm -f /swapfile
    echo "Info: kernel/container does not permit swapon; cleaned up /swapfile and continuing."
    return 0
  fi

  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi

  install -d -m 755 /etc/sysctl.d
  cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness = 10
EOF
  sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1 || true
}

setup_swap "$SWAP_SIZE"

# --- BBR: 仅在内核支持且允许 sysctl 写入时启用 ---
if [[ "$ENABLE_BBR" == "yes" ]]; then
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    install -d -m 755 /etc/sysctl.d
    cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if ! sysctl --system >/dev/null 2>&1; then
      echo "Warning: sysctl --system failed; BBR may not be active until reboot." >&2
    fi
  else
    echo "Info: kernel/container does not expose tcp_bbr; skipping BBR configuration."
  fi
fi

# --- SSH 公钥安装与格式校验 ---
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$SSH_DIR"
touch "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_GROUP" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

auth_keys_has_key() {
  local auth_file="$1"
  local ktype kbody
  read -r ktype kbody _ <<< "$2"
  awk -v t="$ktype" -v b="$kbody" '
    /^[[:space:]]*($|#)/ { next }
    ($1 == t && $2 == b) || ($2 == t && $3 == b) { found=1; exit }
    END { exit !found }
  ' "$auth_file"
}

add_pubkey_line() {
  local line="$1"
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" || "$line" == \#* ]] && return 0
  if [[ "$line" =~ $PUBKEY_REGEX ]]; then
    if ! auth_keys_has_key "$AUTH_KEYS" "$line"; then
      printf '%s\n' "$line" >> "$AUTH_KEYS"
    fi
  else
    echo "Warning: skipped invalid SSH public key line" >&2
  fi
}

add_pubkey_text() {
  local content="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    add_pubkey_line "$line"
  done <<< "$content"
}

if [[ -n "$SSH_PUBLIC_KEY" ]]; then
  add_pubkey_text "$SSH_PUBLIC_KEY"
fi

if [[ -n "$SSH_GITHUB_USER" ]]; then
  echo "Fetching SSH public keys from GitHub user: $SSH_GITHUB_USER"
  if gh_keys="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://github.com/${SSH_GITHUB_USER}.keys")"; then
    add_pubkey_text "$gh_keys"
  else
    echo "Warning: failed to fetch SSH keys from GitHub user: $SSH_GITHUB_USER" >&2
  fi
fi

for key_url in $SSH_KEY_URLS; do
  echo "Fetching SSH public keys from URL: $key_url"
  if url_keys="$(curl -fsSL --connect-timeout 10 --max-time 20 "$key_url")"; then
    add_pubkey_text "$url_keys"
  else
    echo "Warning: failed to fetch SSH keys from URL: $key_url" >&2
  fi
done

chown "$TARGET_USER:$TARGET_GROUP" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# 禁用密码登录前的硬校验：至少存在一条合法公钥，防止把自己锁在门外
if ! grep -Eq "$PUBKEY_REGEX" "$AUTH_KEYS"; then
  echo "Error: no valid SSH public key found in $AUTH_KEYS; refusing to disable password login." >&2
  exit 1
fi

# --- SSH 加固：使用 00- 前缀确保优先于 50-cloud-init.conf 等供应商配置 ---
if [[ -f /etc/ssh/sshd_config ]] && ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  echo "Error: /etc/ssh/sshd_config does not include /etc/ssh/sshd_config.d/*.conf; aborting SSH hardening." >&2
  exit 1
fi

install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/00-key-only.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
ClientAliveInterval 60
ClientAliveCountMax 3
EOF

rm -f /etc/ssh/sshd_config.d/99-key-only.conf
install -d -m 755 /run/sshd

SSHD_BIN="$(command -v sshd || true)"
if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
  SSHD_BIN="/usr/sbin/sshd"
fi
if [[ -z "$SSHD_BIN" ]]; then
  echo "Error: sshd binary not found." >&2
  exit 1
fi

"$SSHD_BIN" -t

if ! (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || service sshd reload 2>/dev/null); then
  echo "Error: failed to reload sshd service." >&2
  exit 1
fi

# --- 可选：安装 Docker（默认关闭，传 INSTALL_DOCKER=yes 启用） ---
if [[ "$INSTALL_DOCKER" == "yes" ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DOCKER_CODENAME="${VERSION_CODENAME:-bookworm}"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL --connect-timeout 15 --max-time 60 https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  DOCKER_ARCH="$(dpkg --print-architecture)"
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${DOCKER_ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${DOCKER_CODENAME} stable
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if [[ ! -f /etc/docker/daemon.json ]]; then
    install -d -m 755 /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  if [[ "$TARGET_USER" != "root" ]] && getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$TARGET_USER" || true
  fi
fi

apt-get clean

# --- Nezha Agent ---
if [[ "$INSTALL_NEZHA" == "yes" ]]; then
  AGENT_SCRIPT="$TMP_DIR/agent.sh"
  curl -fsSL --connect-timeout 15 --max-time 60 \
    https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh \
    -o "$AGENT_SCRIPT"
  chmod +x "$AGENT_SCRIPT"
  env NZ_SERVER="$NZ_SERVER" NZ_TLS="$NZ_TLS" NZ_CLIENT_SECRET="$NZ_CLIENT_SECRET" "$AGENT_SCRIPT"
fi

echo
echo "Hostname:     $(hostname)"
echo "Timezone:     $(cat /etc/timezone 2>/dev/null || timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
if [[ -n "$KERNEL_PKG" ]]; then
  echo "Kernel meta:  ${KERNEL_PKG}=$(dpkg-query -W -f='${Version}' "$KERNEL_PKG" 2>/dev/null || echo unknown)"
fi
echo "Running:      $(uname -r)"
echo "TCP CC:       $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
SWAP_INFO="$(swapon --show --noheadings 2>/dev/null | tr '\n' ';' | sed 's/;$//' || true)"
echo "Swap:         ${SWAP_INFO:-none}"
echo "上面内核 meta 与 Running 不一致时，重启一次以启用新内核。"
echo
echo "Effective sshd settings:"
"$SSHD_BIN" -T | grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|clientaliveinterval|clientalivecountmax) ' || true
echo
echo "Done."
echo "SSH password login is disabled. Public key login remains enabled."
echo "Keep this SSH session open and test a new login:"
echo "ssh -i ~/.ssh/id_ed25519_github ${TARGET_USER}@YOUR_VPS_IP"

if [[ "$INSTALL_DOCKER" == "yes" ]]; then
  echo
  echo "Docker status:"
  echo "docker --version && docker compose version"
fi

if [[ "$INSTALL_NEZHA" == "yes" ]]; then
  echo
  echo "Nezha Agent status:"
  echo "systemctl status nezha-agent --no-pager"
fi

# 可选：AUTO_REBOOT=yes 时自动重启以启用新内核
if [[ "$AUTO_REBOOT" == "yes" ]]; then
  echo
  echo "AUTO_REBOOT=yes，5 秒后重启..."
  sleep 5
  systemctl reboot
fi
