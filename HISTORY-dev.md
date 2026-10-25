# HISTORY-dev.md — what was modified and why

Chronological record of every change in this package, with the evidence
that validated each one. Companion research: `../bcm43602-research/`
(DTrace captures, macOS CLM extraction, probe logs).

## 1. Board identity fix (boardtype / ccode / macaddr)

**What**: embedded NVRAM at file offset `0x7C783` (3,160 B, NUL-separated
`key=value`, `\x00END\x00`-terminated) edited in place:

- `boardtype=0x61b` → `0x171` (Apple MacBookPro14,2)
- `ccode=X0` → `IE`, `regrev=15`
- `macaddr=00:90:4c:0d:f4:3e` (Broadcom universal) → `dc:a9:04:78:42:c8`
  (this unit's Apple burned-in address)

**Why**: the firmware initializes the PHY/PA front-end for the wrong board
→ scan works but nothing transmits; and `X0` breaks the EAPOL/4-way
exchange. Both fixed by the identity change alone.

**Evidence**: `revinfo` debugfs shows `boardid: 0x0171`; association +
WPA2-PSK completes; 60/60 pings 0% loss.

## 2. The boardflags (the RSSI fix)

**What**: `boardflags2=0x00000002` → `0x800002` (+`BFL2_BT_SHARE_ANT0`),
`boardflags3=0x00000003` → `0x5`.

**Why**: stock flags come from Broadcom's reference board. A/B-tested in
place (same physical spot, 2.4G):

| Blob | bfl2/bfl3 | RSSI | link |
|---|---|---|---|
| stock | 0x2 / 0x3 | −78 dBm | rx 1 / tx 24 Mbit/s |
| **shipped** | **0x800002 / 0x5** | **−45 dBm** | rx 120 / tx 162 Mbit/s |
| DeyAgrO combo | 0xC080101B / 0x40000100 | −67 dBm | regression |

The `boardflags3=0x40000100` bit (RCAL_WAR|FEMTBL_FROM_NVRAM) reproduces
the regression; the win comes from `BT_SHARE_ANT0` + the `0x5` bfl3 bit.

## 3. Embedded RF-control variables + block-space re-encoding

**What**: `muxenab=0x1`, `rxchain=7`, `txchain=7`,
`swctrlmap_5g=0xFFFFFFFF,0xFFFFFFF1,0xFFFFFFFF,0xFFFFFFFF,0xF0F0F0F0`
embedded after `seci_on_sprom` (values from the MacBookPro13,2 community
config — DeyAgrO — same chip, PCIe Apple board).

**Why**: the stock block lacks these Apple-board RF-control variables.
The block has zero padding slack, so `pa2g*/pa5g*` PA lists and small hex
scalars are re-encoded hex→decimal (same values, shorter text) to free
space. Verified value-identical; nothing dropped.

## 4. 5GHz unlock — the vendid+devid pair in the NVRAM .txt

**What**: `/lib/firmware/brcm/brcmfmac43602-pcie.txt` containing exactly:

```
vendid=0x14e4
devid=0x43ba
```

**Why**: exhaustive testing (2026-09-14, `../bcm43602-research/analysis/
linux-probes/2026-09-14-5g-clm-tests/`) proved the 7.35 firmware's CLM
has no 5G records for ANY country, `clmload` is unsupported, and the fw
overrides 5G scan-channel requests. The `.txt` file IS read (the
`NVRAMVER[n]=c` dmesg echo with a DEBUG build shows the fw processing the
whole file) but loses all conflicting keys to the embedded block.

**Bisect** (2026-09-16): `nocrc`/`otpimagesize`, `swctrlmapext_5g`,
`swctrlmap_2g`, the trio, and single keys do nothing; **only the complete
`vendid`+`devid` pair** flips the fw bandlist to two bands, makes 5G
beacons appear, and lets 5G association complete (ch36, COMPLETED).
Interpretation: a complete device-identity pair makes the fw treat the
`.txt` as a mergeable board definition and re-evaluate the CLM/board
config. Single keys are treated as fragments.

The pair conflicts with nothing in the embedded block — which is why the
early NVRAM files (conflicting `boardtype`/`ccode`) broke association
while this one does not.

## 5. Driver patches (`driver/` vs stock brcmfmac v7.2-rc7)

1. **chip.c** — two-stage D11 corereset with Apple-derived SICF flags
   (`0x3e2` → `0x3e5`) for BCM43602 (from a DTrace of the working macOS
   driver). Stock only core-disables.
2. **cfg80211.c** — `REGULATORY_COUNTRY_IE_IGNORE` + early-return for
   `NL80211_REGDOM_SET_BY_COUNTRY_IE`: the AP's beacon country-IE otherwise
   triggers a regdom change that deauths right after association.
3. **cfg80211.c (5G)** — the firmware's `GET_BANDLIST` reports 2G-only, so:
   the 5G band is registered by the driver (29 channels, the Apple-CLM
   set), `brcmf_construct_chaninfo` doesn't wipe 5G flags (fw `chanspecs`
   list has no 5G entries), and 5G `bw_cap` is forced to 40/80 MHz.
4. **pcie.c** — debugfs `dump_tcm`, `tcm_write`, `dump_core` for
   firmware-level diagnosis.
5. **p2p.c/p2p.h** — kernel 7.2.x `remain_on_channel` API signature.
6. **cfg80211.c (wedge self-heal)** — delayed-work watchdog: if the STA
   CONNECTING state does not complete within 12 s, the firmware device is
   reset (fw re-download via the bus reset op — the programmatic
   equivalent of the PCIe remove/rescan ritual). Fixes the cold-boot
   wedged-TX state that used to require the manual ritual; also reports
   the stuck attempt as failed so the supplicant retries cleanly.
   Disarmed on connect-done, disconnect and link-down; cancelled at
   teardown. Validated: healthy associations are never disturbed (no
   false fires over dozens of reload cycles), 20/20 pings after every run.
7. **Kbuild** — DEBUG/CONFIG_BRCMDBG on; PCIe-only build (SDIO/USB stubbed),
   WCC vendor plugin only.

### Debug cleanup (2026-09-16)

The research-era debugfs interfaces `dump_tcm`, `tcm_write` and
`dump_core` (raw firmware-memory read/write) were **removed** from
pcie.c — they were forensics tools for the RE phase and are an unnecessary
attack surface in a deployable driver. Kept: `revinfo`, `features`,
`fwcap`, `console_interval` (firmware console, read-only use) and the
manual `reset` escape hatch. Re-validated after removal: 6/6 verify,
5G beacons visible, connection stable.

## 6. Known limits & operating notes

- **First-load wedge**: the firmware occasionally boots with a wedged TX
  path after a cold boot (or many rapid reloads). Recovery: PCIe
  remove/rescan + reload:
  `echo 1 | sudo tee /sys/bus/pci/devices/0000:02:00.0/remove; sleep 2;
   echo 1 | sudo tee /sys/bus/pci/rescan; sudo modprobe brcmfmac`
- **5G signal**: 5G attenuates faster than 2.4G; usable 5G throughput
  needs > −80 dBm. The unlock was validated with association COMPLETED on
  ch36; throughput at weak signal is impractical (physics, not software).
- **5G beacon visibility**: with the `.txt` installed, 5G beacons appear
  in scans; without it, the fw reports a 2G-only bandlist.
- `brcmf_fw_crashed` at boot = the embedded NVRAM block was *replaced*
  (not edited) — only use `scripts/patch-firmware.sh`.
- Do NOT use `ccode=0 --regrev 0` (DeyAgrO combo): degrades 2.4G and
  unlocks nothing on this board.

## 7. Provenance

- Firmware: Broadcom `7.35.177.61` (FWID `01-ea662a8c`) as redistributed
  by `linux-firmware`; NVRAM methodology and 13,2 RF values from
  DeyAgrO/macbook-pro-13-2-linux; board identity from macOS ioreg
  (`boardid 0x171`, `boardrev 0x1108`); 5G channel set + runtime evidence
  from Apple's CLM 8.6.14 (extracted from AirPortBrcmNIC) via the
  `bcm43602-research` DTrace sessions.
- The reference build (`bd32b853…`) and the unlock `.txt` (`356e8b09…`)
  are byte-identical to the validated live installation.

## Timeline

- 2026-09-08: boardtype/ccode identity fix; first stable association
- 2026-09-10: NVRAM v7 (RF vars embedded); 5G investigation begins
- 2026-09-11: live-chip diagnosis tooling (iovar tool, fw console)
- 2026-09-11/12: macOS CLM 8.6.14 extraction + DTrace 5G runtime sessions
- 2026-09-12: boardflags A/B → RSSI −45 dBm
- 2026-09-14: T1-T4 5G root-cause tests (CLM+scan gate proven in fw)
- 2026-09-16: **5G unlocked** (vendid+devid pair); wifi_v2 packaged
- 2026-09-18: live feature-exercise session (feature_matrix.md, driver_gaps.md)
- 2026-09-19: **CLM patching + boot guard → wifi_v3**

## 8. CLM analysis — 5G records found in 7.35 firmware (2026-09-19)

**What**: static analysis of the embedded CLM data at .bin offset 0x8A39C
(69277 bytes). Found 122 5G channel records across 54 unique channels
(ch34-155) using the format: `freq(LE16) + 0x00 + maxpwr(1) + flags(LE16) + 0x02 + 0x00`.

**Why**: the earlier conclusion ("CLM has no 5G records") was wrong — the
records exist but 75/122 have the 0x8000 flag set, which gates scanning.

**Evidence**: `clm_analysis.md`, `capture/clm_735.bin` (extracted CLM blob).

## 9. B4: CLM UNII-1 patch — 5GHz WORKS (2026-09-19)

**What**: cleared 0x8000 on 3 UNII-1 records (ch34, ch42 at two offsets) in
the CLM. Base firmware = B2 (stock boardflags, stable).

**Evidence**: connected to Box_W7-22F153 on ch36 at **−46 dBm, 600 Mbit/s
rx**, 6/6 verify, 0% loss. `clm_breakthrough.md`.

## 10. B8: CLM UNII-3 patch — ch149-165 authorized (2026-09-19)

**What**: repurposed 5 non-standard high-band records (ch145, ch169-172 at
5846-5861 MHz) to UNII-3 frequencies (ch149, 153, 157, 161, 165 at
5745-5825 MHz) using ch155's safe maxpwr (0x3f) and flags (0x000f).

**Failed attempts**: B5 (scattered DFS records → PSM watchdog crash),
B6 (same records with safe values → still PSM crash — wrong CLM section).
B7 (single record ch145→ch149 → stable). B8 (extended with 4 more from
the same section → stable).

**Evidence**: all 5 UNII-3 channels show HT40 allowed in ht40allow_map.
`clm_breakthrough.md`.

## 11. B10: boardflags2=0x800002 + CLM — full feature (2026-09-19)

**What**: combined the v2 boardflags (0x800002/0x5, the SROM-confirmed
hardware value with BFL2_BT_SHARE_ANT0) with the B8 CLM patches.

**Evidence**: **−51 dBm on 2.4G** (vs −76 dBm with stock flags), 5GHz
working, 6/6 verify, 0% loss. Cold-boot wedge present (as expected with
0x800002). SROM dump confirms 0x800002 is the hardware-burned value
(`srom_analysis.md`). macOS ioreg confirms macOS also uses stock
boardflags — the signal gap is firmware-version (7.35 vs 7.77), not
boardflags.

## 12. DFS channels — BLOCKED at firmware level (2026-09-19)

**What**: attempted to clear 0x8000 on DFS records (ch52, ch104, ch116,
ch120 — only 4 records).

**Result**: PSM watchdog crash at boot. The 0x8000 flag on DFS channels
means "DFS required" — the firmware's PSM needs the radar-detection state
machine. Clearing it without enabling DFS crashes the MAC.

**Conclusion**: DFS channels (ch52-144) cannot be unlocked via CLM
patching on firmware 7.35. Only a newer firmware (7.77) with a modern
DFS implementation could handle this.

## 13. Wedge watchdog patch — fires but bus_reset incomplete (2026-09-19)

**What**: patched the v2 wedge watchdog to track cumulative connect time
across supplicant state cycles (instead of resetting on every link-down).
Added `arm()` to `brcmf_cfg80211_connect()`, made `disarm()` a no-op,
added `cancel()` for successful connect/disconnect only.

**Result**: the watchdog **correctly fires** after 12s cumulative connect
time ("wedge watchdog firing — bus_reset after 12000ms"). But
`brcmf_bus_reset()` → `brcmf_pcie_reset()` brings the bus down without
fully re-probing the device (PCI device stuck, module refcount -1, PCI
remove denied). Only a full PCI remove/rescan or reboot recovers.

**Conclusion**: the in-driver bus reset path is incomplete for this PCIe
fullmac driver on 7.35 firmware. The watchdog detection works; the
recovery doesn't. Reverted the driver patches.

## 14. Systemd boot guard — auto-recovers wedge (2026-09-19)

**What**: a systemd oneshot service (`brcmfmac-wedge-recovery.service`)
that runs 20s after boot, checks if wlan0 is connected, and if not,
performs the PCI remove/rescan ritual automatically.

**Evidence** (cold-boot log):
```
23:30:42 — systemd: Starting BCM43602 wedged-TX recovery
23:31:02 — wlan0 not connected after 20s — performing PCIe remove/rescan ritual
23:31:27 — wlan0 connected after ritual on attempt 1
23:31:27 — systemd: Finished BCM43602 wedged-TX recovery
```

Total recovery: ~45s. Fully automated, no user intervention.

**Files**: `/usr/local/sbin/brcmfmac-wedge-recovery.sh`,
`/etc/systemd/system/brcmfmac-wedge-recovery.service`.

## 15. Provenance (wifi_v3 additions)

- CLM patching methodology: original reverse-engineering of the 7.35
  firmware's embedded CLM binary format (122 5G records found, 0x8000
  scan-gate flag identified, ch155 used as safe template for UNII-3).
- SROM analysis: `capture/srom_dump.bin` (4096 bytes, word-duplicated)
  confirmed boardflags2=0x800002 is the hardware-burned value.
- Boot guard: the PCI remove/rescan ritual was already documented in
  wifi_v2's HISTORY-dev §6; the systemd service automates it.
- The extended `patch-firmware.sh` reproduces the B10 binary exactly
  (sha256 `634e2a54…`) from the pristine blob with `--clm-all`.

## Updated timeline

- 2026-09-19: CLM analysis, B4 (5GHz ch36 working), B8 (UNII-3), B10 (full
  feature: −51 dBm + 5GHz), DFS blocked, watchdog patch (fires but
  incomplete recovery), boot guard (auto-recovery in ~45s), **wifi_v3 packaged**
