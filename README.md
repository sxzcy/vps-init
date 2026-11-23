# vps-init

Debian VPS bootstrap & SSH public key helper scripts.

## 1. 一键添加 SSH 公钥 (`key.sh`)

默认添加内置公钥到当前用户的 `~/.ssh/authorized_keys`（自动校验格式、语义去重、修正权限）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh)
```

常用参数组合：

```bash
# 添加默认公钥并禁用 SSH 密码登录（写入 /etc/ssh/sshd_config.d/00-key-only.conf）
bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh) -d

# 从 GitHub 同步全部公钥
bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh) -g sxzcy

# 从自定义 URL 拉取公钥（类似 git.io/key.sh -u）
bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh) -u https://example.com/id_ed25519.pub

# 指定系统用户并覆盖原 authorized_keys
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh) -U debian -o
```

支持选项：
- `-g <user>`：从 `https://github.com/<user>.keys` 拉取公钥（可重复指定）
- `-u <url>`：从指定 URL 拉取公钥（可重复指定）
- `-f <path>`：从本地文件读取公钥（可重复指定）
- `-U <user>`：目标系统用户（默认当前用户）
- `-o`：覆盖 `authorized_keys`（仅在校验新公钥有效后原子替换）
- `-d`：禁用 SSH 密码登录并自动执行 `sshd -t` 校验与重载

---

## 2. Debian VPS 全量初始化 (`setup-debian.sh`)

在全新 Debian VPS 上以 `root` 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/setup-debian.sh -o setup-debian.sh
NZ_CLIENT_SECRET='your_nezha_client_secret' bash setup-debian.sh
```

常用组合示例：

```bash
# 不装 Nezha Agent，只初始化系统
INSTALL_NEZHA=no bash setup-debian.sh

# 顺便改主机名 + 安装 Docker + 完成后自动重启启用新内核
NEW_HOSTNAME=tokyo-01 INSTALL_DOCKER=yes AUTO_REBOOT=yes NZ_CLIENT_SECRET='your_secret' bash setup-debian.sh
```

常用环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TARGET_USER` | `root` | 安装 SSH 公钥的目标用户 |
| `SSH_PUBLIC_KEY` | 内置公钥 | 要写入的默认公钥 |
| `SSH_GITHUB_USER` | 空 | 可选：额外同步指定 GitHub 账号的公钥 |
| `SSH_KEY_URLS` | 空 | 可选：额外拉取的公钥 URL（空格分隔） |
| `TIMEZONE` | `Asia/Shanghai` | 系统时区（设为 `keep` 保持原样） |
| `NEW_HOSTNAME` | 空 | 可选：设置系统主机名并同步 `/etc/hosts` |
| `SWAP_SIZE` | `auto` | `auto`（无 Swap 且内存 ≤ 2G 时自动建 1G）、具体大小如 `2G`，或 `0` 关闭 |
| `ENABLE_BBR` | `yes` | 是否启用 TCP BBR（`fq + bbr`，内核支持时生效） |
| `ENABLE_UNATTENDED_UPGRADES` | `yes` | 是否开启安全补丁自动更新（不自动重启） |
| `INSTALL_DOCKER` | `no` | 设为 `yes` 时安装官方 Docker + Compose 并限制容器日志 50MB×3 |
| `INSTALL_NEZHA` | `yes` | 设为 `no` 可跳过 Nezha Agent 安装 |
| `NZ_SERVER` | `agent-nezha.knowx.top:443` | Nezha Agent 上报地址 |
| `NZ_TLS` | `true` | Nezha Agent TLS 开关 |
| `NZ_CLIENT_SECRET` | 必填（当 `INSTALL_NEZHA=yes`） | Nezha Agent 密钥 |
| `AUTO_REBOOT` | `no` | 设为 `yes` 时完成后 5 秒自动重启 |

脚本会完成以下操作：
- 非交互式更新系统与常用排障/运维包（`tmux`、`jq`、`dnsutils`、`mtr-tiny`、`lsof`、`ncdu`、`gnupg`、`chrony` 等），按当前内核类型（cloud / 标准）显式升级内核 meta 包
- 统一系统时区，限制 `systemd-journald` 日志体积（`200M` / `1month`），开启仅打安全补丁的 `unattended-upgrades`
- 小内存机器（≤ 2 GB 且无 Swap）自动兜底 1G swapfile（`vm.swappiness=10`），并按需启用 TCP BBR
- 校验并语义去重写入 SSH 公钥，确认非空后通过 `/etc/ssh/sshd_config.d/00-key-only.conf` 禁用密码登录、开启 SSH 保活并核验生效配置
- 按需安装 Docker（官方源 + 日志限额）和 Nezha Agent

Do not close the current SSH session until a new SSH key login has been tested successfully.
