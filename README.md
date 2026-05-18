# vps-init

Debian VPS bootstrap script.

## Usage

Run this on a fresh Debian VPS as root:

```bash
curl -fsSL https://raw.githubusercontent.com/sxzcy/vps-init/main/setup-debian.sh -o setup-debian.sh
NZ_CLIENT_SECRET='your_nezha_client_secret' bash setup-debian.sh
```

The script installs common packages, adds the configured SSH public key, disables SSH password login, and installs the Nezha Agent.

Do not close the current SSH session until a new SSH key login has been tested successfully.
