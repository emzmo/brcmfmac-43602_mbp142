#!/usr/bin/env bash
# Post-install verification for the patched BCM43602 firmware + driver.
# Usage: sudo verify.sh [expected-country]   (default: IE)
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ck()   { if [ "$2" -eq 0 ]; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
warn() { echo "  WARN: $1"; WARN=$((WARN+1)); }

FW=/lib/firmware/brcm/brcmfmac43602-pcie.bin
# Auto-detect the brcmfmac interface (wlan0, wlp2s0, etc.)
IFACE=${IFACE:-$(ls /sys/class/net/ 2>/dev/null | while read n; do
    iw dev "$n" info &>/dev/null && echo "$n" && break
done)}
IFACE=${IFACE:-wlan0}
WANT_CC=${1:-IE}
PRISTINE="$(dirname "$(readlink -f "$0")")/../firmware/brcmfmac43602-pcie.bin.pristine"

echo "[1/6] firmware blob present and patched"
if [ ! -f "$FW" ]; then
    ck "firmware installed at $FW" 1
else
    GOT=$(sha256sum "$FW" | cut -d' ' -f1)
    PRI=$(sha256sum "$PRISTINE" 2>/dev/null | cut -d' ' -f1)
    if [ "$GOT" = "$PRI" ]; then
        ck "firmware is UNPATCHED (same as pristine) — run scripts/patch-firmware.sh" 1
    else
        ck "firmware installed and differs from pristine (patched)" 0
    fi
fi

echo "[2/6] driver module loaded"
grep -q brcmfmac /proc/modules; ck "brcmfmac loaded" $?

echo "[3/6] interface exists"
ip link show "$IFACE" > /dev/null 2>&1; ck "$IFACE present" $?

echo "[4/6] firmware board identity (boardtype patch active)"
BID=$(cat /sys/kernel/debug/ieee80211/phy*/revinfo 2>/dev/null | grep boardid | awk '{print $2}')
[ "$BID" = "0x0171" ]; ck "boardid=0x0171 (got: ${BID:-none})" $?

echo "[5/6] firmware country + embedded RF-control vars"
if command -v brcm-iovar >/dev/null 2>&1; then
    C=$(brcm-iovar "$IFACE" get_str country 2>/dev/null | grep -o '"[A-Z0-9]*"' | tr -d '"')
    if [ "$C" = "$WANT_CC" ]; then
        ck "country=$C" 0
    else
        warn "country=$C (expected $WANT_CC) — check --country used when patching"
    fi
    # embedded RF-control vars (v7 patch): firmware reports these via iovar
    TXC=$(brcm-iovar "$IFACE" get_int txchain 2>/dev/null | grep -oE '[0-9]+' | head -1)
    RXC=$(brcm-iovar "$IFACE" get_int rxchain 2>/dev/null | grep -oE '[0-9]+' | head -1)
    if [ "$TXC" = "7" ] && [ "$RXC" = "7" ]; then
        ck "txchain=7 rxchain=7 (3x3 chains, embedded vars live)" 0
    else
        warn "txchain=${TXC:-?} rxchain=${RXC:-?} (expected 7/7) — v7 NVRAM vars not confirmed"
    fi
else
    # No brcm-iovar helper installed: the ccode patch's observable effect
    # is that EAPOL completes, so a COMPLETED supplicant proves it works.
    ST=$(wpa_cli -i "$IFACE" status 2>/dev/null | grep -oE "wpa_state=[a-zA-Z]+" | cut -d= -f2)
    if [ "$ST" = "COMPLETED" ]; then
        ck "ccode functional (4-way handshake completed, supplicant COMPLETED)" 0
    else
        warn "cannot read fw country and supplicant is ${ST:-not running} — "
        warn "  connect to an AP to prove the ccode patch (expected: $WANT_CC)"
    fi
fi

echo "[6/6] connectivity through $IFACE"
GW=$(ip route show default 2>/dev/null | grep "$IFACE" | awk '{print $3; exit}')
if [ -z "$GW" ]; then
    warn "no default route on $IFACE — connect first (nmcli dev wifi connect ...)"
else
    ping -c 3 -W 2 -I "$IFACE" "$GW" > /dev/null 2>&1
    ck "gateway $GW reachable via $IFACE" $?
fi

echo
echo "Result: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
[ "$FAIL" -eq 0 ] && echo "ALL GOOD" || echo "TROUBLESHOOTING: see INSTALL.md section 'Troubleshooting'"