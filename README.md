# wifi_v3 — Full-feature WiFi for MacBookPro14,2 (BCM43602) on Arch Linux

**wifi_v3 = wifi_v2 + CLM patches (5GHz unlock) + boot guard (cold-boot self-heal).**

Ready-to-deploy package for the Broadcom BCM43602 (PCI `14e4:43ba`) in the
MacBook Pro 14,2. This is the final build: stable 2.4G with proper signal
(−51 dBm class), **5GHz unlocked** (UNII-1 ch36-48 working, UNII-3 ch149-165
authorized), and automatic cold-boot wedge recovery.

## What it changes vs wifi_v2

**1. The firmware `.bin`** — same embedded NVRAM block as v2 (boardtype 0x171,
ccode IE, boardflags2=0x800002 for RSSI, RF-control vars) **plus two CLM
patches applied to the embedded CLM data at offset 0x8A39C**:

| CLM patch | What | Effect |
|---|---|---|
| UNII-1 | Clear 0x8000 on 3 records (ch34-48) | 5GHz scanning enabled on non-DFS channels |
| UNII-3 | Repurpose 5 high-band records to ch149-165 | UNII-3 channels authorized in band table |

**2. A systemd boot guard** (`brcmfmac-wedge-recovery.service`) — 20s after
boot, checks if wlan0 is connected. If not, performs the PCIe remove/rescan
ritual automatically. Recovers the cold-boot TX wedge (caused by
boardflags2=0x800002) in ~45s with no user intervention.

**3. The driver** — unchanged from v2 (DKMS brcmfmac-mbp142 1.0.0).

## Quick start

```bash
# one-command install
sudo scripts/install.sh
# or with debug logging:
sudo scripts/install.sh --debug

# reboot to activate
sudo systemctl reboot

# after reboot (~45s for boot guard), verify:
sudo scripts/verify.sh IE
# expect: 6/6 PASS
```

## Rebuilding from the pristine blob

```bash
python3 scripts/patch-firmware.sh --country IE --regrev 15 \
    --mac dc:a9:04:78:42:c8 --clm-all
# -> brcmfmac43602-pcie.bin (sha256 634e2a54…) + the .txt
```

Override with `--country`, `--mac`, `--boardflags2 stock`, `--no-clm` etc.
Run `python3 scripts/patch-firmware.sh --help` for all options.

## What works

| Feature | Status | Detail |
|---|---|---|
| 2.4 GHz STA | **WORKING** | −51 dBm, 68-89% signal, 0% loss |
| 5 GHz UNII-1 (ch36-48) | **WORKING** | validated −46 dBm, 600 Mbit/s on ch36 |
| 5 GHz UNII-3 (ch149-165) | **AUTHORIZED** | ht40allow HT40, no AP tested |
| Cold-boot stability | **AUTO-RECOVERS** | boot guard: ~45s, no user action |
| verify.sh | **6/6 PASS** | |
| WPA2-PSK | **WORKING** | 4-way handshake completes |
| AP mode | **WORKING** (radio level) | tested via NM hotspot |
| P2P | **WORKING** (mechanism) | p2p_find accepted, no peers nearby |

## What doesn't work

| Feature | Status | Reason |
|---|---|---|
| 5 GHz DFS (ch52-144) | **BLOCKED** | firmware 7.35 requires DFS state machine; clearing 0x8000 crashes PSM |
| Suspend/resume | **UNTESTED** | known system crasher on earlier builds (s2idle + WoWLAN) |
| Cold boot (first 20s) | **WEDGED** | boardflags2=0x800002 causes TX wedge; boot guard recovers automatically |

## Requirements

- MacBook Pro 14,2 with BCM43602 rev 2 (PCI `14e4:43ba`)
- Arch Linux (tested on kernel 7.2.4-arch1-2)
- `linux-headers` (matching your kernel), `dkms`, `networkmanager`,
  `wireless-regdb`
- `wpa_supplicant` (pulled by NetworkManager)

## Cold-boot behavior

On cold boot, the firmware comes up with a wedged TX path (caused by the
`BFL2_BT_SHARE_ANT0` flag in boardflags2=0x800002, which is the hardware
SROM-confirmed correct value but the 7.35 firmware doesn't handle it
correctly at cold init). The boot guard service detects this 20s after
boot and performs a PCIe remove/rescan, which re-downloads the firmware
and brings up the TX path correctly. Total recovery: ~45s. No user
intervention needed.

If the boot guard fails (rare), manual recovery:
```bash
echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove
sleep 2
echo 1 | sudo tee /sys/bus/pci/rescan
```

## Files

```
firmware/
  brcmfmac43602-pcie.bin           patched firmware (the actual fix)
  brcmfmac43602-pcie.bin.pristine  unmodified reference (for diffing)
  brcmfmac43602-pcie.txt           NVRAM — two-key 5G unlock
  SHA256SUMS                       integrity reference
driver/                           full DKMS source tree (brcmfmac-mbp142 1.0.0)
scripts/
  patch-firmware.sh               build the .bin from pristine (+ CLM patches)
  build-driver.sh                 dkms add/build/install helper
  verify.sh                       post-install verification battery
  brcmfmac-wedge-recovery.sh      boot guard script
  install.sh                      one-command deploy
INSTALL.md                        step-by-step fresh-install guide
HISTORY-dev.md                    every change and its evidence
```

## Legal note

Firmware blobs are Broadcom firmware as redistributed by `linux-firmware`
(same license terms). The `.txt`/NVRAM values are device-identity and
board-configuration data for interoperability. Driver sources: Linux
kernel brcmfmac (GPL) with local modifications.