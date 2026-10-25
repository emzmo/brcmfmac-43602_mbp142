#!/bin/bash
# brcmfmac-wedge-recovery.sh — auto-recover from cold-boot TX wedge
# Called by systemd after boot. If wlan0 isn't connected within 20s,
# performs the PCI remove/rescan ritual (the documented recovery).
set -eu

# Auto-detect the BCM43602 PCI device
PCI_DEV=$(lspci -d 14e4:43ba -D 2>/dev/null | awk '{print $1}' | head -1)
if [ -z "$PCI_DEV" ]; then
    echo "[brcmfmac-wedge-recovery] BCM43602 PCI device not found — exiting"
    exit 0
fi

# Auto-detect the wlan interface
IFACE=$(ls /sys/class/net/ 2>/dev/null | while read n; do
    iw dev "$n" info &>/dev/null && echo "$n" && break
done)
IFACE=${IFACE:-wlan0}

WAIT_SECS=20
MAX_RETRIES=2

for attempt in $(seq 1 $MAX_RETRIES); do
    # Wait for connection
    sleep $WAIT_SECS

    # Check if connected (wpa_state=COMPLETED or carrier up)
    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q 'wpa_state=COMPLETED'; then
        echo "[brcmfmac-wedge-recovery] $IFACE connected on attempt $attempt — no action needed"
        exit 0
    fi

    # Not connected — check if interface exists
    if ! ip link show "$IFACE" &>/dev/null; then
        echo "[brcmfmac-wedge-recovery] $IFACE does not exist on attempt $attempt — skipping"
        exit 0
    fi

    echo "[brcmfmac-wedge-recovery] $IFACE not connected after ${WAIT_SECS}s (attempt $attempt) — performing PCIe remove/rescan ritual"

    # Disconnect NM to stop supplicant interference
    nmcli dev disconnect "$IFACE" 2>/dev/null || true
    sleep 2

    # PCIe remove/rescan ritual
    if [ -f "/sys/bus/pci/devices/$PCI_DEV/remove" ]; then
        echo 1 > "/sys/bus/pci/devices/$PCI_DEV/remove" 2>/dev/null || true
        sleep 3
    fi

    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 8

    # Wait for the driver to re-probe and NM to connect
    sleep 10

    if wpa_cli -i "$IFACE" status 2>/dev/null | grep -q 'wpa_state=COMPLETED'; then
        echo "[brcmfmac-wedge-recovery] $IFACE connected after ritual on attempt $attempt"
        exit 0
    fi
done

echo "[brcmfmac-wedge-recovery] failed after $MAX_RETRIES attempts — manual intervention needed"
exit 1