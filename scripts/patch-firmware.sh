#!/usr/bin/env python3
"""Build a region/board-correct BCM43602 firmware from the pristine blob.

The stock brcmfmac43602-pcie.bin embeds a 3160-byte NVRAM block describing
Broadcom's reference board (boardtype=0x61b, ccode=X0).  The firmware
ignores the host-supplied NVRAM file, so this script rewrites the embedded
block directly inside the binary:

    boardtype=0x171   Apple MacBookPro14,2 board identity (radio-TX fix)
    ccode=XX          your ISO country code (EAPOL fix)
    macaddr=...       unique address (the stock blob is universal)

In addition the block gains the Apple-board RF-control variables that the
stock block omits entirely (values from the MacBookPro13,2 community
config, DeyAgrO/macbook-pro-13-2-linux — same chip, PCI 14e4:43ba):

    muxenab=0x1       antenna/rf mux enable
    rxchain=7         explicit 3x3 receive chain
    txchain=7         explicit 3x3 transmit chain
    swctrlmap_5g=...  5GHz antenna switch control (weak-signal/5G fix)

Board flags and the RF calibration values stay untouched.  To free space
for the four new keys the pa2g*/pa5g* PA parameters and boardflags2/3 are
re-encoded from hex lists to the signed-decimal form of the SAME values
(mathematically identical — this is just the other textual representation
the SROM parser accepts).  Nothing outside the embedded block changes.

Example:
    ./patch-firmware.sh --country IE --regrev 15 \
        --mac dc:a9:04:78:42:c8 \
        --out brcmfmac43602-pcie.bin
"""

import argparse
import hashlib
import re
import secrets
import struct
import sys

BLOCK_OFFSET = 0x7C783
BLOCK_LENGTH = 3160
END_MARKER = b"\x00END\x00"
PRISTINE_SHA256 = "bf4cfc23ee952a3d82ef33a0f5f87853201c98f1bed034876a910f354f37862d"

# CLM data location in the firmware binary
CLM_OFFSET = 0x8A39C

# CLM record format: freq(LE16) + 0x00 + maxpwr(1) + flags(LE16) + band(1=2.4G,2=5G) + 0x00
# 5G records have band=0x02. The 0x8000 flag bit gates scanning.

# UNII-1 channels (ch34-48, non-DFS, universally allowed)
UNII1_CHANNELS = {34, 36, 38, 40, 42, 44, 46, 48}

# UNII-3 records to create by repurposing non-standard high-band records.
# Each tuple: (offset, new_freq, new_ch). Uses ch155's safe maxpwr=0x3f, flags=0x000f.
UNII3_REPURPOSE = [
    (0x996f8, 5745, 149),  # ch145(5725) -> ch149(5745)
    (0x99af0, 5765, 153),  # ch169(5846) -> ch153(5765)
    (0x99b18, 5785, 157),  # ch170(5854) -> ch157(5785)
    (0x99b50, 5805, 161),  # ch171(5858) -> ch161(5805)
    (0x99b68, 5825, 165),  # ch172(5861) -> ch165(5825)
]
UNII3_MAXPWR = 0x3f    # from ch155 (the existing UNII-3 record)
UNII3_FLAGS = 0x000f   # from ch155

# Apple burned-in MAC of this unit (reference: firmware/nvram-*-v7.txt).
DEFAULT_MAC = "dc:a9:04:78:42:c8"

# RF-control variables the stock embedded block lacks.  Values from the
# MacBookPro13,2 community config (DeyAgrO/macbook-pro-13-2-linux) — the
# community's field-validated settings for this chip on a PCIe Apple board.
DEFAULT_INSERTS = {
    "muxenab": "0x1",
    "rxchain": "7",
    "txchain": "7",
    "swctrlmap_5g": "0xFFFFFFFF,0xFFFFFFF1,0xFFFFFFFF,0xFFFFFFFF,0xF0F0F0F0",
}

# Boardflags overrides — A/B validated 2026-09-12 (see INSTALL.md): RSSI
# -78 -> -45 dBm at the same physical spot next to the AP.  Pass
# '--boardflags2 stock --boardflags3 stock' to keep the Broadcom
# reference-board values instead.
DEFAULT_BOARDFLAGS = {
    "boardflags2": "0x800002",   # +BFL2_BT_SHARE_ANT0
    "boardflags3": "0x5",
}
STOCK_BOARDFLAGS = {
    "boardflags2": "0x00000002",
    "boardflags3": "0x00000003",
}


def parse_args():
    ap = argparse.ArgumentParser(
        description="Patch the embedded NVRAM of a BCM43602 firmware blob.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Example:")[-1],
    )
    ap.add_argument("--boardtype", default="0x171",
                    help="board type (default: 0x171, Apple MacBookPro14,2)")
    ap.add_argument("--country", default="IE",
                    help="two-letter ISO country code (default: IE)")
    ap.add_argument("--regrev", default="15",
                    help="regulatory revision (default: 15)")
    ap.add_argument("--mac", default=DEFAULT_MAC,
                    help="MAC address (default: this unit's Apple burned-in "
                         "address %s); pass 'random' for a generated unique "
                         "locally-administered one" % DEFAULT_MAC)
    ap.add_argument("--muxenab", default=DEFAULT_INSERTS["muxenab"],
                    help="value for the added muxenab variable")
    ap.add_argument("--rxchain", default=DEFAULT_INSERTS["rxchain"],
                    help="value for the added rxchain variable")
    ap.add_argument("--txchain", default=DEFAULT_INSERTS["txchain"],
                    help="value for the added txchain variable")
    ap.add_argument("--swctrlmap5g", default=DEFAULT_INSERTS["swctrlmap_5g"],
                    help="value for the added swctrlmap_5g variable")
    ap.add_argument("--no-swctrlmap", action="store_true",
                    help="do not embed swctrlmap_5g (revert to pre-v7 behaviour)")
    ap.add_argument("--boardflags2", default=DEFAULT_BOARDFLAGS["boardflags2"],
                    help="boardflags2 override (default: 0x800002 = "
                         "+BT_SHARE_ANT0, A/B validated RSSI fix; pass 'stock' "
                         "for the Broadcom reference value 0x2)")
    ap.add_argument("--boardflags3", default=DEFAULT_BOARDFLAGS["boardflags3"],
                    help="boardflags3 override (default: 0x5, A/B validated; "
                         "pass 'stock' for the Broadcom reference value 0x3; "
                         "the DeyAgrO 0x40000100 tested WORSE)")
    ap.add_argument("--in", dest="infile", default="firmware/brcmfmac43602-pcie.bin.pristine",
                    help="input firmware (default: %(default)s)")
    ap.add_argument("--out", dest="outfile", default="brcmfmac43602-pcie.bin",
                    help="output firmware (default: %(default)s)")
    ap.add_argument("--force", action="store_true",
                    help="allow an input that is not the pristine blob")
    ap.add_argument("--clm-unii1", action="store_true", default=False,
                    help="patch CLM: clear 0x8000 on UNII-1 5G records (ch34-48) "
                         "to enable 5GHz scanning on non-DFS channels")
    ap.add_argument("--clm-unii3", action="store_true", default=False,
                    help="patch CLM: repurpose 5 high-band records to UNII-3 "
                         "channels (ch149-165) using ch155's safe power/flags")
    ap.add_argument("--clm-all", action="store_true", default=False,
                    help="apply both CLM patches (default if no CLM flag is given)")
    ap.add_argument("--no-clm", action="store_true",
                    help="skip CLM patching entirely (NVRAM-only build)")
    return ap.parse_args()


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_block(block):
    """Parse the embedded NVRAM block into an ordered [(key, value)] list.

    Entries are NUL-separated `key=value` strings followed by an END
    trailer.  Anything unparseable before END is preserved verbatim so the
    serialisation round-trip is lossless.
    """
    entries = []
    pos = 0
    content_end = block.find(b"END\x00")
    limit = content_end if content_end != -1 else len(block)
    while pos < limit:
        m = re.match(rb"([A-Za-z0-9_]+)=([^\x00]*)\x00", block[pos:limit])
        if not m:
            pos += 1
            continue
        entries.append((m.group(1).decode(), m.group(2).decode("latin-1")))
        pos += m.end()
    return entries


def serialize_block(entries):
    """Serialise entries + END trailer; returns bytes (unpadded)."""
    out = bytearray()
    for key, val in entries:
        out += key.encode() + b"=" + val.encode("latin-1") + b"\x00"
    out += b"END\x00"
    return bytes(out)


def s16_hexlist_to_decimal(value):
    """`0xff3c,0x172c,...` -> `-196,5932,...` (signed 16-bit, same values)."""
    parts = value.split(",")
    out = []
    for p in parts:
        x = int(p, 16)
        if x >= 0x8000:
            x -= 0x10000
        out.append(str(x))
    return ",".join(out)


REENCODABLE_KEYS = {
    "boardrev", "boardtype", "subvid",
    "rawtempsense", "measpower", "measpower1", "measpower2",
    "tempsense_slope", "tempcorrx", "tempsense_option",
    "subband5gver",
    "pa2ga0", "pa2ga1", "pa2ga2",
    "pa5ga0", "pa5ga1", "pa5ga2",
    "boardflags2", "boardflags3",
}


def reencode_for_space(entries):
    """Re-encode hex values as decimal to free block space.

    Several variables are stored as `0x…` strings in the stock block; the
    identical integers written in decimal are shorter (e.g. PA params are
    the same signed 16-bit numbers in the other textual representation the
    SROM parser accepts; boardflags2/3 of the stock blob are tiny 0x2/0x3).
    boardflags/boardtype/boardrev/subvid are deliberately NOT touched here
    (identity keys, and boardflags' decimal form saves just 1 byte).
    Returns (new_entries, changes).
    """
    out = []
    changes = []
    for key, val in entries:
        nv = val
        if key in REENCODABLE_KEYS and re.fullmatch(
                r"0x[0-9a-fA-F]{1,8}(,0x[0-9a-fA-F]{1,8})*", val or ""):
            if key.startswith("pa"):
                nv = s16_hexlist_to_decimal(val)
            else:
                dec = str(int(val, 16))
                if len(dec) < len(val):
                    nv = dec
        if nv != val:
            changes.append((key, val, nv))
        out.append((key, nv))
    return out, changes


def set_var(entries, key, value):
    """Set key=value in the entry list (insert before END when absent).

    Returns (new_entries, changed_or_inserted_bool).
    """
    value_b = value.encode() if isinstance(value, str) else value
    found = False
    out = []
    for k, v in entries:
        if k == key:
            out.append((k, value))
            found = True
        else:
            out.append((k, v))
    if not found:
        # insert after the last regular entry (before the END trailer)
        idx = max((i for i, (k, _) in enumerate(entries)
                   if k != "END"), default=len(entries) - 1)
        out = entries[:]
        out.insert(idx + 1, (key, value))
    return out, found


def parse_user_var_value(key, value, expected_len=None):
    if expected_len and len(value) != expected_len:
        fail(f"{key}={value!r} has {len(value)} chars, expected {expected_len} "
             f"(length-changing values are not supported for this key)")
    return value


def main():
    args = parse_args()

    # ---- validate arguments -------------------------------------------
    args.boardtype = args.boardtype.lower()
    if not re.fullmatch(r"0x[0-9a-f]{3,}", args.boardtype):
        fail(f"--boardtype {args.boardtype!r} is not a hex value like 0x171")
    # Normalise hex (0x073e == 0x73e): the DeyAgrO NVRAM writes the
    # 4-digit form, the embedded block uses the stripped form.
    args.boardtype = "0x" + args.boardtype[2:].lstrip("0") or "0x0"

    # Country: ISO 2-letter codes, plus Broadcom's 1-2 char special codes
    # (DeyAgrO's proven combo uses ccode=0, the stock blob uses X0).
    args.country = args.country.upper()
    if not re.fullmatch(r"[0-9A-Z]{1,2}", args.country):
        fail(f"--country {args.country!r} must be 1-2 uppercase letters/digits "
             f"(ISO code, or a Broadcom code like X0/X2/XW/0)")

    if not args.regrev.isdigit():
        fail(f"--regrev {args.regrev!r} must be a decimal number")

    for flag_name in ("boardflags2", "boardflags3"):
        val = getattr(args, flag_name)
        if val is not None:
            val = val.lower()
            if val == "stock":
                setattr(args, flag_name, STOCK_BOARDFLAGS[flag_name])
                continue
            if not re.fullmatch(r"0x[0-9a-f]{1,8}", val):
                fail(f"--{flag_name} {val!r} is not a hex value like 0x800002 "
                     f"(or 'stock')")
            setattr(args, flag_name, val)

    if args.mac is None or args.mac.lower() == "random":
        # Locally administered, unicast.
        mac_bytes = bytearray(secrets.token_bytes(6))
        mac_bytes[0] = (mac_bytes[0] | 0x02) & 0xFE
        args.mac = ":".join(f"{b:02x}" for b in mac_bytes)
        print(f"[i] no fixed MAC given, generated unique MAC: {args.mac}")
    if not re.fullmatch(r"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", args.mac):
        fail(f"--mac {args.mac!r} is not a valid AA:BB:CC:DD:EE:FF address")
    args.mac = args.mac.lower()

    # ---- read input ----------------------------------------------------
    try:
        fw = open(args.infile, "rb").read()
    except OSError as e:
        fail(f"cannot read {args.infile}: {e}")

    if len(fw) != 635449:
        fail(f"{args.infile} has {len(fw)} bytes, expected 635449 — "
             f"is this really a BCM43602 pcie firmware?")

    got = hashlib.sha256(fw).hexdigest()
    if got != PRISTINE_SHA256 and not args.force:
        fail(f"{args.infile} sha256 {got} does not match the pristine blob "
             f"({PRISTINE_SHA256}); pass --force if you know what you are doing")

    block = fw[BLOCK_OFFSET:BLOCK_OFFSET + BLOCK_LENGTH]
    if len(block) != BLOCK_LENGTH or END_MARKER not in block:
        fail(f"embedded NVRAM block not found at offset {BLOCK_OFFSET:#x} — "
             f"unexpected firmware layout")

    # ---- apply patches -------------------------------------------------
    state = {"entries": parse_block(block)}
    changes = []

    # 1) re-encode pa*/flags hex lists as decimal to free block space
    state["entries"], re_changes = reencode_for_space(state["entries"])
    changes.extend(("reencode " + k, o, n) for k, o, n in re_changes)

    # 2) identity/country/MAC patches
    def apply(key, value):
        prev = next((v for k, v in state["entries"] if k == key), None)
        # numeric equality first (0x2 == 2 == 0x00000002) so same-value
        # rewrites in a different textual form are not applied
        same = prev == value
        if not same and prev is not None and value is not None:
            try:
                pv = int(prev, 16) if prev.startswith("0x") else int(prev)
                vv = int(value, 16) if value.startswith("0x") else int(value)
                same = (pv == vv)
            except (ValueError, AttributeError):
                same = False
        if not same:
            state["entries"], _ = set_var(state["entries"], key, value)
            changes.append((key, prev, value))

    apply("boardtype", args.boardtype)
    apply("ccode", args.country)
    apply("regrev", args.regrev)
    apply("macaddr", args.mac)

    # 2b) boardflags overrides (only when explicitly requested)
    for flag_name in ("boardflags2", "boardflags3"):
        val = getattr(args, flag_name)
        if val is not None:
            apply(flag_name, val)

    # 3) embed the RF-control variables the stock block lacks
    inserts = {
        "muxenab": args.muxenab,
        "rxchain": args.rxchain,
        "txchain": args.txchain,
    }
    if not args.no_swctrlmap:
        inserts["swctrlmap_5g"] = args.swctrlmap5g
    for key, value in inserts.items():
        existing = next((v for k, v in state["entries"] if k == key), None)
        if existing == value:
            continue
        state["entries"], _ = set_var(state["entries"], key, value)
        changes.append(("add " + key, existing, value))

    # ---- serialise and pad ---------------------------------------------
    new_block = serialize_block(state["entries"])
    if len(new_block) > BLOCK_LENGTH:
        fail(f"patched block would be {len(new_block)} bytes, exceeds "
             f"{BLOCK_LENGTH} — the embedded NVRAM has no slack for values "
             f"this long; shorten --country/--mac or drop --swctrlmap5g")
    new_block += b"\x00" * (BLOCK_LENGTH - len(new_block))
    block = new_block

    if not changes:
        print("[i] nothing to change — the firmware already has these values")
    fw = fw[:BLOCK_OFFSET] + block + fw[BLOCK_OFFSET + BLOCK_LENGTH:]

    # ---- CLM patching --------------------------------------------------
    fw = bytearray(fw)  # make mutable for in-place CLM edits
    # Default: if no CLM flag is explicitly given, apply both (--clm-all).
    # --no-clm skips everything. --clm-unii1/--clm-unii3 apply selectively.
    explicit_clm = args.clm_unii1 or args.clm_unii3 or args.no_clm
    clm_all = args.clm_all or not explicit_clm  # default when nothing specified
    do_clm_unii1 = args.clm_unii1 or (clm_all and not args.no_clm)
    do_clm_unii3 = args.clm_unii3 or (clm_all and not args.no_clm)
    clm_changes = []

    if do_clm_unii1:
        patched = 0
        for i in range(CLM_OFFSET, len(fw) - 8):
            freq = struct.unpack_from('<H', fw, i)[0]
            if (5000 <= freq <= 6000 and fw[i+2] == 0x00
                    and fw[i+6] == 0x02 and fw[i+7] == 0x00):
                ch = (freq - 5000) // 5
                if ch in UNII1_CHANNELS:
                    flags = struct.unpack_from('<H', fw, i + 4)[0]
                    if flags & 0x8000:
                        struct.pack_into('<H', fw, i + 4, flags & 0x7FFF)
                        patched += 1
        clm_changes.append(f"CLM UNII-1: cleared 0x8000 on {patched} records (ch34-48)")

    if do_clm_unii3:
        patched = 0
        for offset, new_freq, new_ch in UNII3_REPURPOSE:
            struct.pack_into('<H', fw, offset, new_freq)
            fw[offset + 3] = UNII3_MAXPWR
            struct.pack_into('<H', fw, offset + 4, UNII3_FLAGS)
            fw[offset + 6] = 0x02
            fw[offset + 7] = 0x00
            patched += 1
        clm_changes.append(f"CLM UNII-3: repurposed {patched} records -> ch149,153,157,161,165")

    out_sha = hashlib.sha256(fw).hexdigest()

    try:
        open(args.outfile, "wb").write(fw)
    except OSError as e:
        fail(f"cannot write {args.outfile}: {e}")

    # 5GHz unlock: the firmware's NVRAM loader legalizes the 5G band when a
    # host NVRAM .txt carrying a complete (vendid, devid) device identity
    # pair is downloaded (A/B validated 2026-09-16: bandlist 1-band -> 2-band,
    # 5G association COMPLETED). The pair must be EXACTLY these two keys —
    # either alone is ignored, and any conflicting key would be overridden
    # by the embedded block anyway. Ship the .txt next to the .bin.
    txt_out = args.outfile.rsplit(".", 1)[0] + ".txt"
    try:
        open(txt_out, "w").write("vendid=0x14e4\ndevid=0x43ba\n")
        print(f"5GHz unlock NVRAM written to: {txt_out}")
        print("  install it as /lib/firmware/brcm/brcmfmac43602-pcie.txt")
    except OSError as e:
        print(f"ERROR: cannot write {txt_out}: {e}", file=sys.stderr)

    # ---- report --------------------------------------------------------
    print()
    print(f"Patched firmware written to: {args.outfile}")
    print(f"  sha256: {out_sha}")
    for name, old, new in changes:
        print(f"  {name}: {old if old is not None else '(absent)'} -> {new}")
    for clm_change in clm_changes:
        print(f"  {clm_change}")
    if not changes and not clm_changes:
        print("  (identical to input)")
    print()
    print("Deploy:")
    print(f"  sudo cp {args.outfile} /lib/firmware/brcm/brcmfmac43602-pcie.bin")
    print("Then reload the driver (or reboot) and check:")
    print("  cat /sys/kernel/debug/ieee80211/phy*/revinfo | grep boardid")
    print(f"  -> expect boardid: {args.boardtype}")


if __name__ == "__main__":
    main()