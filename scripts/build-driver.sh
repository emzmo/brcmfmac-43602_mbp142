#!/usr/bin/env bash
# Build and install the patched brcmfmac driver via DKMS.
# Source tree: driver/ (brcmfmac-mbp142, version 1.0.0)
set -euo pipefail

DKMS_NAME="brcmfmac-mbp142"
DKMS_VER="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/../driver"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

# Stop the stock driver if loaded
modprobe -r brcmfmac_wcc 2>/dev/null || true
modprobe -r brcmfmac 2>/dev/null || true

# Register + build + install
if ! dkms status | grep -q "^${DKMS_NAME}/${DKMS_VER}"; then
  dkms add "${SRC_DIR}"
fi
dkms build "${DKMS_NAME}/${DKMS_VER}" --force
dkms install "${DKMS_NAME}/${DKMS_VER}" --force

# Driver config: blacklist the stock module name and auto-load ours at
# boot (the DKMS-renamed module lost its PCI modalias, so an explicit
# modules-load entry is required). Idempotent.
echo "blacklist brcmfmac" | tee /etc/modprobe.d/brcmfmac-mbp142.conf > /dev/null
echo "brcmfmac-wcc" | tee /etc/modules-load.d/brcmfmac-mbp142.conf > /dev/null

echo
echo "Installed. Load with: modprobe brcmfmac"
echo "(conf files written: /etc/modprobe.d + /etc/modules-load.d/brcmfmac-mbp142.conf)"
