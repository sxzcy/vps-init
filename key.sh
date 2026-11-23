#!/usr/bin/env bash
set -euo pipefail

# Default SSH public key (installed when no -g / -u / -f source is specified)
DEFAULT_SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIvWfTreCb3RCCDpCO2oEytXYs27/L3gW3b/gavJ0Cdn sxzcy1993@gmail.com'
PUBKEY_REGEX='^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+'

OVERWRITE=0
DISABLE_PASSWORD=0
TARGET_USER="${TARGET_USER:-}"
GITHUB_USERS=()
KEY_URLS=()
KEY_FILES=()
COLLECTED_KEYS=()

usage() {
  cat <<'EOF'
Usage:
  bash <(curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/key.sh) [options]

Without -g/-u/-f, installs the built-in default SSH public key.

Options:
  -g <user>   Fetch public keys from GitHub (https://github.com/<user>.keys); repeatable
  -u <url>    Fetch public keys from a URL; repeatable
  -f <path>   Read public keys from a local file; repeatable
  -U <user>   Target system user (default: current user, or $TARGET_USER)
  -o          Overwrite authorized_keys instead of appending (only after validating keys)
  -d          Disable SSH password login via /etc/ssh/sshd_config.d/00-key-only.conf
  -h          Show this help message
EOF
}

key_fingerprint_pair() {
  awk '{print $1 " " $2}' <<< "$1"
}

auth_keys_has_key() {
  local auth_file="$1"
  local pair="$2"
  local ktype kbody
  read -r ktype kbody <<< "$pair"
  awk -v t="$ktype" -v b="$kbody" '
    /^[[:space:]]*($|#)/ { next }
    ($1 == t && $2 == b) || ($2 == t && $3 == b) { found=1; exit }
    END { exit !found }
  ' "$auth_file"
}

collect_key_line() {
  local line="$1"
  local pair existing
  line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" || "$line" == \#* ]] && return 0

  if [[ "$line" =~ $PUBKEY_REGEX ]]; then
    pair="$(key_fingerprint_pair "$line")"
    for existing in "${COLLECTED_KEYS[@]+"${COLLECTED_KEYS[@]}"}"; do
      [[ "$(key_fingerprint_pair "$existing")" == "$pair" ]] && return 0
    done
    COLLECTED_KEYS+=("$line")
  else
    echo "Warning: skipped invalid SSH public key line" >&2
  fi
}

collect_from_text() {
  local content="$1"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    collect_key_line "$line"
  done <<< "$content"
}

while getopts ":og:u:f:U:dh" opt; do
  case "$opt" in
    o) OVERWRITE=1 ;;
    g) GITHUB_USERS+=("$OPTARG") ;;
    u) KEY_URLS+=("$OPTARG") ;;
    f) KEY_FILES+=("$OPTARG") ;;
    U) TARGET_USER="$OPTARG" ;;
    d) DISABLE_PASSWORD=1 ;;
    h) usage; exit 0 ;;
    :) echo "Error: option -$OPTARG requires an argument." >&2; usage >&2; exit 1 ;;
    \?) echo "Error: unknown option -$OPTARG." >&2; usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
  echo "Error: unexpected positional arguments: $*" >&2
  usage >&2
  exit 1
fi

CURRENT_USER="$(id -un)"
if [[ -z "$TARGET_USER" ]]; then
  TARGET_USER="$CURRENT_USER"
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "Error: user does not exist: $TARGET_USER" >&2
  exit 1
fi

if [[ "$TARGET_USER" != "$CURRENT_USER" && "$EUID" -ne 0 ]]; then
  echo "Error: please run as root (or via sudo) when installing keys for another user: $TARGET_USER" >&2
  exit 1
fi

if [[ "${#GITHUB_USERS[@]}" -eq 0 && "${#KEY_URLS[@]}" -eq 0 && "${#KEY_FILES[@]}" -eq 0 ]]; then
  collect_key_line "$DEFAULT_SSH_PUBLIC_KEY"
else
  for gh_user in "${GITHUB_USERS[@]+"${GITHUB_USERS[@]}"}"; do
    echo "Fetching SSH public keys from GitHub user: $gh_user"
    content="$(curl -fsSL --connect-timeout 10 --max-time 20 "https://github.com/${gh_user}.keys")" || {
      echo "Error: failed to fetch keys for GitHub user: $gh_user" >&2
      exit 1
    }
    collect_from_text "$content"
  done

  for url in "${KEY_URLS[@]+"${KEY_URLS[@]}"}"; do
    echo "Fetching SSH public keys from URL: $url"
    content="$(curl -fsSL --connect-timeout 10 --max-time 20 "$url")" || {
      echo "Error: failed to fetch keys from URL: $url" >&2
      exit 1
    }
    collect_from_text "$content"
  done

  for file_path in "${KEY_FILES[@]+"${KEY_FILES[@]}"}"; do
    if [[ ! -r "$file_path" ]]; then
      echo "Error: cannot read key file: $file_path" >&2
      exit 1
    fi
    echo "Reading SSH public keys from file: $file_path"
    collect_from_text "$(cat "$file_path")"
  done
fi

if [[ "${#COLLECTED_KEYS[@]}" -eq 0 ]]; then
  echo "Error: no valid SSH public keys found; aborting without modifying authorized_keys." >&2
  exit 1
fi

USER_HOME=""
if command -v getent >/dev/null 2>&1; then
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
fi
if [[ -z "$USER_HOME" && "$TARGET_USER" == "$CURRENT_USER" && -n "${HOME:-}" ]]; then
  USER_HOME="$HOME"
fi
if [[ -z "$USER_HOME" ]]; then
  USER_HOME="$(eval echo "~$TARGET_USER")"
fi
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  echo "Error: home directory not found for user $TARGET_USER: $USER_HOME" >&2
  exit 1
fi

TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || id -g "$TARGET_USER")"
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

ADDED=0
SKIPPED=0

if [[ "$OVERWRITE" -eq 1 ]]; then
  TMP_KEYS="$(mktemp "${SSH_DIR}/.authorized_keys.XXXXXX")"
  trap 'rm -f "${TMP_KEYS:-}"' EXIT
  for key in "${COLLECTED_KEYS[@]}"; do
    printf '%s\n' "$key" >> "$TMP_KEYS"
    ADDED=$((ADDED + 1))
  done
  chmod 600 "$TMP_KEYS"
  mv -f "$TMP_KEYS" "$AUTH_KEYS"
  trap - EXIT
else
  touch "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS"
  for key in "${COLLECTED_KEYS[@]}"; do
    if auth_keys_has_key "$AUTH_KEYS" "$(key_fingerprint_pair "$key")"; then
      SKIPPED=$((SKIPPED + 1))
    else
      printf '%s\n' "$key" >> "$AUTH_KEYS"
      ADDED=$((ADDED + 1))
    fi
  done
fi

if [[ "$EUID" -eq 0 ]]; then
  chown "$TARGET_USER:$TARGET_GROUP" "$SSH_DIR" "$AUTH_KEYS"
fi

echo "SSH public keys updated for ${TARGET_USER} (${AUTH_KEYS}): added=${ADDED}, already_present=${SKIPPED}, mode=$([[ "$OVERWRITE" -eq 1 ]] && echo overwrite || echo append)"

if [[ "$DISABLE_PASSWORD" -eq 1 ]]; then
  if ! grep -Eq "$PUBKEY_REGEX" "$AUTH_KEYS"; then
    echo "Error: no valid SSH public key present in $AUTH_KEYS; refusing to disable password login." >&2
    exit 1
  fi

  SUDO_CMD=()
  if [[ "$EUID" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO_CMD=(sudo)
    else
      echo "Error: disabling SSH password login requires root or sudo." >&2
      exit 1
    fi
  fi

  if [[ -f /etc/ssh/sshd_config ]] && ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    echo "Error: /etc/ssh/sshd_config does not include /etc/ssh/sshd_config.d/*.conf; refusing to write drop-in silently." >&2
    exit 1
  fi

  "${SUDO_CMD[@]}" install -d -m 755 /etc/ssh/sshd_config.d
  "${SUDO_CMD[@]}" tee /etc/ssh/sshd_config.d/00-key-only.conf >/dev/null <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

  if [[ -f /etc/ssh/sshd_config.d/99-key-only.conf ]]; then
    "${SUDO_CMD[@]}" rm -f /etc/ssh/sshd_config.d/99-key-only.conf
  fi

  "${SUDO_CMD[@]}" install -d -m 755 /run/sshd

  SSHD_BIN="$(command -v sshd || true)"
  if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
    SSHD_BIN="/usr/sbin/sshd"
  fi
  if [[ -z "$SSHD_BIN" ]]; then
    echo "Error: sshd binary not found." >&2
    exit 1
  fi

  "${SUDO_CMD[@]}" "$SSHD_BIN" -t

  if command -v systemctl >/dev/null 2>&1; then
    "${SUDO_CMD[@]}" systemctl reload ssh 2>/dev/null || "${SUDO_CMD[@]}" systemctl reload sshd
  elif command -v service >/dev/null 2>&1; then
    "${SUDO_CMD[@]}" service ssh reload 2>/dev/null || "${SUDO_CMD[@]}" service sshd reload
  else
    echo "Error: unable to reload sshd automatically (neither systemctl nor service found)." >&2
    exit 1
  fi

  echo "SSH password login disabled (/etc/ssh/sshd_config.d/00-key-only.conf). Effective sshd settings:"
  "${SUDO_CMD[@]}" "$SSHD_BIN" -T | grep -E '^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitrootlogin) ' || true
  echo "Keep this SSH session open and verify a new key login before disconnecting."
fi
