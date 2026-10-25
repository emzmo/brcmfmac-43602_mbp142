# INSTALL.md — reproduce wifi_v3 on a fresh Arch install (MacBook Pro 14,2)

## Dependencies (fresh Arch install)

```bash
sudo pacman -S --needed linux-headers dkms networkmanager wireless-regdb
```

| Package | Why |
|---|---|
| `linux-headers` | matching your kernel — DKMS compiles against it |
| `dkms` | rebuilds the driver on kernel updates |
| `networkmanager` | network stack; pulls `wpa_supplicant` |
| `wireless-regdb` | country database (the fix uses `IE`) |

## Option A: One-command install

```bash
cd wifi_v3
sudo scripts/install.sh
sudo systemctl reboot
```

After reboot (~45s for boot guard), verify:
```bash
sudo scripts/verify.sh IE
# expect: 6 passed, 0 failed, 0 warnings — ALL GOOD
```

## Option B: Step-by-step manual install

### 0. Pre-flight: confirm the hardware

```bash
lspci -nn | grep -i 14e4
# expect: Network controller: Broadcom Inc. ... BCM43602 [14e4:43ba] (rev 02)
```

### 1. Install the patched firmware

```bash
sudo cp firmware/brcmfmac43602-pcie.bin /lib/firmware/brcm/brcmfmac43602-pcie.bin
sudo cp firmware/brcmfmac43602-pcie.txt /lib/firmware/brcm/brcmfmac43602-pcie.txt
sha256sum -c firmware/SHA256SUMS    # must report OK
```

### 2. Install the patched driver (DKMS)

```bash
sudo scripts/build-driver.sh
```

What it does:
- `dkms add` the source tree
- `dkms build` + `dkms install`
- writes `/etc/modprobe.d/brcmfmac-mbp142.conf` (blacklist stock brcmfmac)
- writes `/etc/modules-load.d/brcmfmac-mbp142.conf` (auto-load brcmfmac-wcc)

### 3. Install the boot guard (wedge recovery)

```bash
sudo cp scripts/brcmfmac-wedge-recovery.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/brcmfmac-wedge-recovery.sh

sudo tee /etc/systemd/system/brcmfmac-wedge-recovery.service <<'EOF'
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
EOF

sudo systemctl daemon-reload
sudo systemctl enable brcmfmac-wedge-recovery
```

### 4. (Optional) Enable debug logging

```bash
sudo tee /etc/modprobe.d/brcmfmac-debug.conf <<'EOF'
# BCM43602 rev2 debug level (brcmfmac msglevel bitmask)
options brcmfmac debug=0x1F1000
EOF
```

### 5. Reboot

```bash
sudo systemctl reboot
```

### 6. Verify

```bash
sudo scripts/verify.sh IE
```

Expected output:
```
[1/6] firmware blob present and patched
  PASS: firmware installed and differs from pristine (patched)
[2/6] driver module loaded
  PASS: brcmfmac loaded
[3/6] interface exists
  PASS: wlan0 present
[4/6] firmware board identity (boardtype patch active)
  PASS: boardid=0x0171 (got: 0x0171)
[5/6] firmware country + embedded RF-control vars
  PASS: ccode functional (4-way handshake completed, supplicant COMPLETED)
[6/6] connectivity through wlan0
  PASS: gateway ... reachable via wlan0

Result: 6 passed, 0 failed, 0 warnings
ALL GOOD
```

### 7. Check signal and 5GHz

```bash
iw dev wlan0 link
# expect: signal: -45 to -55 dBm on 2.4G (vs -76 dBm without the fix)

nmcli dev wifi
# expect: 5 GHz APs visible (BAND = 5 GHz)

iw dev wlan0 scan | grep 'freq: 5'
# expect: 5G BSS entries
```

## Troubleshooting

### Interface exists but never associates (cold-boot wedge)

The boot guard should handle this automatically (~45s). If it doesn't:

```bash
# Check boot guard log:
journalctl -u brcmfmac-wedge-recovery

# Manual recovery:
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan
# wait 10s, then:
nmcli dev connect wlan0
```

### PSM watchdog crash (firmware crash at boot)

This happens if the CLM patch is wrong. The prebuilt `.bin` in
`firmware/` is validated. If rebuilding with `patch-firmware.sh`, ensure
you use `--clm-all` (default) and don't add `--no-clm` by mistake. Do NOT
clear 0x8000 on DFS channels (ch52-144) — it crashes the firmware's PSM.

### Connection drops right after associating (reason=0)

This was the country-IE regdom bug — fixed in the driver
(`REGULATORY_COUNTRY_IE_IGNORE`). If you rebuild the driver without that
patch, you will see it again on APs that broadcast a country IE.

### Firmware crashes at boot (`brcmf_fw_crashed`)

The embedded NVRAM block was *replaced* (not edited). Only use
`scripts/patch-firmware.sh` to patch the firmware — don't manually edit
the binary.

### No 5GHz APs visible

1. Check `cat /sys/kernel/debug/ieee80211/phy*/ht40allow_map | grep 5`
   — should show 5G channels with HT40 allowed
2. Move near a 5GHz AP — 5G attenuates faster than 2.4G
3. Check `journalctl -k | grep escan_prep.*Chan : 36` — should show the
   driver sending 5G chanspecs to the firmware
4. DFS channels (ch52-144) are not available — only UNII-1 (ch36-48) and
   UNII-3 (ch149-165) work

## What "fixed" means here

| Before (v1) | After (v3) |
|---|---|
| 2.4G only, −77 dBm, 49% signal | 2.4G + 5GHz, −51 dBm, 68-89% signal |
| No 5GHz | 5GHz ch36-48 working, ch149-165 authorized |
| Wedges on cold boot (manual ritual) | Auto-recovers in ~45s (boot guard) |
| verify: N/A | verify: 6/6 PASS |