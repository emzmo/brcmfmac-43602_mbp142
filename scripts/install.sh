#!/usr/bin/env bash
# install.sh — one-command deploy for wifi_v3 (BCM43602 MacBookPro14,2)
#
# Usage:
#   sudo scripts/install.sh           # standard install
#   sudo scripts/install.sh --debug   # also write debug=0x1F1000 modprobe conf
#
# Does:
#   1. Copy firmware (.bin + .txt) to /lib/firmware/brcm/
#   2. Build + install the DKMS driver
#   3. Install the wedge-recovery boot guard (systemd service)
#   4. Optionally write the debug modprobe conf
#   5. Print "Reboot to activate"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/.."
FW_DIR="/lib/firmware/brcm"
DEBUG=false

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

# Parse args
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=true ;;
        --help)  echo "Usage: sudo scripts/install.sh [--debug]"; exit 0 ;;
        *)       echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

echo "=== wifi_v3 install (BCM43602 MacBookPro14,2) ==="
echo

# 1. Firmware
echo "[1/4] Installing firmware..."
mkdir -p "$FW_DIR"
# Verify source integrity BEFORE copying
(cd "$PKG_DIR/firmware" && sha256sum -c SHA256SUMS) || { echo "  ERROR: SHA256 mismatch — aborting"; exit 1; }
cp "$PKG_DIR/firmware/brcmfmac43602-pcie.bin" "$FW_DIR/brcmfmac43602-pcie.bin"
cp "$PKG_DIR/firmware/brcmfmac43602-pcie.txt" "$FW_DIR/brcmfmac43602-pcie.txt"
echo "  OK: firmware installed"

# 2. Driver (DKMS)
echo
echo "[2/4] Building + installing driver (DKMS)..."
bash "$SCRIPT_DIR/build-driver.sh"
echo "  OK: driver installed"

# 3. Boot guard (wedge recovery)
echo
echo "[3/4] Installing wedge-recovery boot guard..."
cp "$SCRIPT_DIR/brcmfmac-wedge-recovery.sh" /usr/local/sbin/brcmfmac-wedge-recovery.sh
chmod +x /usr/local/sbin/brcmfmac-wedge-recovery.sh

cat > /etc/systemd/system/brcmfmac-wedge-recovery.service <<'UNIT'
[Unit]
Description=BCM43602 wedged-TX recovery (cold-boot guard)
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/brcmfmac-wedge-recovery.sh
RemainAfterExit=yes
SuccessExitStatus=0 1

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable brcmfmac-wedge-recovery.service
echo "  OK: boot guard enabled (auto-recovers cold-boot wedge in ~45s)"

# 4. Debug config (optional)
if $DEBUG; then
    echo
    echo "[4/4] Writing debug modprobe conf..."
    cat > /etc/modprobe.d/brcmfmac-debug.conf <<'CONF'
# BCM43602 rev2 debug level (brcmfmac msglevel bitmask)
# Bits (debug.h): FIL 0x1000 | SCAN 0x4000 | CONN 0x8000 |
#                 MSGBUF 0x40000 | PCIE 0x80000 | FWCON 0x100000
options brcmfmac debug=0x1F1000
CONF
    echo "  OK: debug=0x1F1000 written to /etc/modprobe.d/brcmfmac-debug.conf"
else
    echo
    echo "[4/4] Skipping debug conf (use --debug to enable)"
fi

echo
echo "=== Install complete ==="
echo
echo "Next steps:"
echo "  1. Reboot: sudo systemctl reboot"
echo "  2. After reboot (~45s), verify: sudo $SCRIPT_DIR/verify.sh IE"
echo "  3. Expected: 6/6 PASS, -51 dBm on 2.4G, 5GHz visible in scans"
echo
echo "Cold-boot behavior: the boot guard auto-recovers the TX wedge"
echo "via PCIe remove/rescan if wlan0 isn't connected within 20s."