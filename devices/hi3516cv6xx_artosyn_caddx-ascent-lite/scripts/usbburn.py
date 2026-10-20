#!/usr/bin/env python3
"""Flash, back up and recover the Ascent air unit over USB -- no serial adapter, no opening.

Hold the bind button while powering on and keep holding: the boot ROM enumerates as
3361:d001 "Vendor" for ~3 s (not used), then the stock U-Boot re-enumerates as 3361:d001
"VENDOR" and stays in download mode until power-off. This tool waits for the second one.
It only works while the boot partition (U-Boot) is intact -- otherwise use defib + serial.

Wire protocol (U-Boot drivers/usb/gadget/udc3/usb3_prot.c), bulk EP 0x01 out / 0x81 in:
  FA 00 00                  start          -> AA 00
  FE <len BE32> <addr BE32> head           -> AA 00; the next <len> bytes are DMA'd to addr
  ED                        tail           -> AA 00 (55 00 if fewer bytes arrived)
  AB 00 00 <command> 00     run_command()  -> console output + "[EOT](OK)" | "[EOT](ERROR)"
Quirks this tool works around:
  * Console output lands in a 400-byte rolling buffer, so only the tail of long output
    survives (why `help`/`printenv` look cut off). Only puts() is mirrored to USB, not
    putc(), so md's line breaks are missing. Data comes back via `md.l`, 96 bytes per
    command, so dumps skip erased pages using `crc32` and CRC-check every page they read.
  * Every console byte also goes out the UART and blocks at 115200 baud (~33 ms per md
    command, ~2 KiB/s). While working, the PL011 is set to UARTCLK/16 (1.5 Mbaud) and put
    back afterwards; serial output is garbage meanwhile.
  * After ERROR, U-Boot never re-arms its OUT endpoint and ignores everything after it.
    SET_CONFIGURATION re-arms it (Link.recover); on a healthy link it would arm it twice and
    wedge it until power-off, so it is only ever sent right after an ERROR.
  * nand commands only take numeric offsets (no mtdparts support compiled in); erases must
    be block-aligned and writes page-aligned, or they fail.
  * U-Boot believes it has 64 MB and lives at the top of it, so images go through RAM in
    4 MB chunks at 0x42000000, CRC-checked after upload and again after the NAND write.

Needs pyusb and a udev rule, e.g. /etc/udev/rules.d/82-hisilicon-usbburn.rules:
  SUBSYSTEM=="usb", ATTR{idVendor}=="3361", ATTR{idProduct}=="d001", MODE="0666"
"""

import argparse
import re
import struct
import sys
import time
import zlib
from pathlib import Path

import usb.core
import usb.util

VID, PID = 0x3361, 0xD001
EP_OUT, EP_IN = 0x01, 0x81
USTART, UHEAD, UTAIL, UCMD = 0xFA, 0xFE, 0xED, 0xAB
ACK, NAK = 0xAA, 0x55

PAGE = 0x800
BLOCK = 0x20000
RAM_A = 0x42000000
RAM_B = 0x42400000
CHUNK_BLOCKS = 32

# Stock bootargs: mtdparts=nand:512K(boot),512K(env),1M(sel),4M(kernel0),4M(kernel1),
# 6M(factory),16M(rootfs0),16M(rootfs1),32M(usrdata0),32M(usrdata1)
PARTITIONS = {
    "boot": (0x0000000, 0x0080000),
    "env": (0x0080000, 0x0080000),
    "sel": (0x0100000, 0x0100000),
    "kernel0": (0x0200000, 0x0400000),
    "kernel1": (0x0600000, 0x0400000),
    "factory": (0x0A00000, 0x0600000),
    "rootfs0": (0x1000000, 0x1000000),
    "rootfs1": (0x2000000, 0x1000000),
    "usrdata0": (0x3000000, 0x2000000),
    "usrdata1": (0x5000000, 0x2000000),
}
PROTECTED = {"boot", "env", "sel", "factory"}
NO_RETURN = {"reset", "fpvboot", "boot", "bootm"}

BSEL_TRAILER = bytes([0xEE, 0x98, 0x0C, 0x53])
FIT_MAGIC = b"\xd0\x0d\xfe\xed"
UBIFS_MAGIC = b"\x31\x18\x10\x06"
UBIFS_SB_NODE = 6
UBIFS_FLG_SPACE_FIXUP = 0x04
ASW_MAGIC = 0x575341

EOT_RE = re.compile(r"\[EOT\]\((OK|ERROR)\)\s*$")
CRC_RE = re.compile(r"==>\s*([0-9a-fA-F]{8})")
UART_BASE = 0x11040000
UART_IBRD, UART_FBRD, UART_LCRH, UART_CR = 0x24, 0x28, 0x2C, 0x30
UART_DIV_115200 = (13, 1)
FF_PAGE_CRC = zlib.crc32(b"\xff" * PAGE)
FF_BLOCK_CRC = zlib.crc32(b"\xff" * BLOCK)


class LinkError(Exception):
    pass


def human(n):
    if n >= 0x100000:
        return f"{n / 0x100000:.1f}".rstrip("0").rstrip(".") + " MiB"
    return f"{n / 1024:.0f} KiB"


def progress(label, done, total, t0):
    rate = done / max(time.monotonic() - t0, 1e-3) / 1024
    print(f"\r  {label}: {done * 100 // total:3d}%  {human(done)} / {human(total)}"
          f"  {rate:.0f} KiB/s   ", end="", flush=True)


def find_device(wait):
    deadline = time.monotonic() + wait
    told = set()
    while True:
        dev = usb.core.find(idVendor=VID, idProduct=PID)
        mfr = None
        if dev is not None:
            try:
                mfr = usb.util.get_string(dev, dev.iManufacturer)
            except usb.core.USBError as e:
                if e.errno == 13:
                    sys.exit("permission denied on 3361:d001 -- install the udev rule (see --help)")
            except ValueError:
                pass
            if mfr == "VENDOR":
                return dev
            if mfr == "Vendor" and "rom" not in told:
                print("boot ROM stage -- keep holding bind, waiting for U-Boot ...")
                told.add("rom")
        elif "wait" not in told:
            print(f"waiting up to {wait:.0f} s for the air unit (hold bind while powering on) ...")
            told.add("wait")
        if time.monotonic() >= deadline:
            if dev is not None and mfr is None:
                print("warning: cannot read the device's strings, trying anyway")
                return dev
            if dev is not None:
                sys.exit("device is still in the boot ROM stage -- hold bind longer")
            sys.exit("no 3361:d001 device found")
        time.sleep(0.25)


def parse_md(text, addr, length, width=4):
    """md lines arrive without newlines (putc isn't mirrored): walk the expected address tags."""
    field = 2 * width + 1
    word_re = re.compile(rf"(?: [0-9a-fA-F]{{{2 * width}}})+")
    out = bytearray()
    pos = 0
    for a in range(addr, addr + length, 16):
        n = min(16, addr + length - a)
        i = text.find(f"{a:08x}:", pos)
        if i < 0:
            return None
        hexpart = text[i + 9:i + 9 + field * (n // width)]
        if len(hexpart) != field * (n // width) or not word_re.fullmatch(hexpart):
            return None
        for word in hexpart.split():
            out += int(word, 16).to_bytes(width, "little")
        pos = i + 9 + len(hexpart) + n  # skip the ASCII column: data can't fake a tag
    return bytes(out)


class Link:
    def __init__(self, dev):
        self.dev = dev
        self.md_chunk = 0x60
        self._bad = None
        self._uart = None

    def _write(self, data, timeout=5.0):
        try:
            self.dev.write(EP_OUT, data, timeout=int(timeout * 1000))
        except usb.core.USBTimeoutError:
            raise LinkError("the device stopped accepting data -- power-cycle it (holding bind)"
                            " and retry") from None

    def _read(self, timeout):
        try:
            return bytes(self.dev.read(EP_IN, 4096, timeout=max(1, int(timeout * 1000))))
        except usb.core.USBTimeoutError:
            return b""

    def _expect_ack(self, what):
        resp = self._read(5.0)
        if resp[:1] != bytes([ACK]):
            raise LinkError(f"{what}: expected ACK, got {resp.hex() or 'nothing'} -- if an earlier"
                            " run was interrupted during an upload, power-cycle the device")

    def drain(self):
        out = b""
        while chunk := self._read(0.5):
            out += chunk
        return out.decode("latin-1").replace("\0", "").strip()

    def handshake(self):
        self.drain()
        self._write(bytes([USTART, 0, 0]))
        self._expect_ack("start")
        self._write(struct.pack(">BII", UHEAD, 0, 0))
        self._expect_ack("connect")

    def send(self, command):
        self._write(bytes([UCMD, 0, 0]) + command.encode() + b"\0")

    def run(self, command, timeout=10.0):
        """Returns (ok, output); on ERROR U-Boot sends no output -- recover() fetches it."""
        self.send(command)
        deadline = time.monotonic() + timeout
        buf = ""
        while (left := deadline - time.monotonic()) > 0:
            buf += self._read(left).decode("latin-1").replace("\0", "")
            m = EOT_RE.search(buf)
            if m:
                out = buf[:m.start()]
                return m.group(1) == "OK", out[1:] if out.startswith(" ") else out
        raise LinkError(f"no reply to '{command}' within {timeout:.0f} s")

    def recover(self):
        """Re-arm the endpoint after an ERROR; returns the failed command's output."""
        try:
            usb.util.release_interface(self.dev, 0)
        except Exception:
            pass
        try:
            self.dev.set_configuration()
        except usb.core.USBError as e:
            raise LinkError(f"link recovery failed ({e}) -- power-cycle the device") from None
        self.drain()
        _, leftover = self.run("true", timeout=5)
        return leftover.strip()

    def cmd(self, command, timeout=10.0):
        ok, out = self.run(command, timeout)
        if ok:
            return out
        try:
            reason = self.recover()
        except LinkError as e:
            raise LinkError(f"'{command}' failed; {e}") from None
        raise LinkError(f"'{command}' failed" + (f": {reason}" if reason else ""))

    def fire(self, command):
        """Send a command that never returns on success (reset, fpvboot)."""
        self.restore_console()
        self.send(command)
        try:
            resp = self._read(3.0).decode("latin-1")
        except usb.core.USBError:
            return
        if "[EOT](ERROR)" in resp:
            reason = self.recover()
            raise LinkError(f"'{command}' failed" + (f": {reason}" if reason else ""))

    def crc32(self, addr, length):
        out = self.cmd(f"crc32 0x{addr:x} 0x{length:x}")
        m = CRC_RE.search(out)
        if not m:
            raise LinkError(f"unexpected crc32 output: {out!r}")
        return int(m.group(1), 16)

    def upload(self, addr, data):
        self._write(struct.pack(">BII", UHEAD, len(data), addr))
        self._expect_ack("upload head")
        for i in range(0, len(data), 0x10000):
            self._write(data[i:i + 0x10000], timeout=10)
        self._write(bytes([UTAIL]))
        resp = self._read(5.0)
        if resp[:1] != bytes([ACK]):
            short = resp[:1] == bytes([NAK])
            raise LinkError("upload tail: " + ("device got fewer bytes than announced" if short
                                               else f"got {resp.hex() or 'nothing'}"))
        if self.crc32(addr, len(data)) != zlib.crc32(data):
            raise LinkError(f"CRC mismatch after uploading {human(len(data))} to 0x{addr:x}")

    def read_words(self, addr, count):
        data = parse_md(self.cmd(f"md.l 0x{addr:x} 0x{count:x}"), addr, 4 * count)
        if data is None:
            raise LinkError(f"cannot parse md.l output at 0x{addr:x}")
        return struct.unpack(f"<{count}I", data)

    def _set_uart(self, ibrd, fbrd, lcrh, cr):
        u = UART_BASE
        self.cmd(f"mw.l 0x{u + UART_CR:x} 0x0; mw.l 0x{u + UART_IBRD:x} 0x{ibrd:x}; "
                 f"mw.l 0x{u + UART_FBRD:x} 0x{fbrd:x}; mw.l 0x{u + UART_LCRH:x} 0x{lcrh:x}; "
                 f"mw.l 0x{u + UART_CR:x} 0x{cr:x}")

    def fast_console(self):
        """Console output also blocks on the 115200 UART; run it at UARTCLK/16 meanwhile."""
        ibrd, fbrd, lcrh, cr = self.read_words(UART_BASE + UART_IBRD, 4)
        if not cr & 1 or not ibrd:
            print(f"note: unexpected UART state (IBRD 0x{ibrd:x} CR 0x{cr:x}), left alone")
            return
        if (ibrd, fbrd) == (1, 0):
            ibrd, fbrd = UART_DIV_115200
        self._uart = (ibrd, fbrd, lcrh, cr)
        self._set_uart(1, 0, lcrh, cr)

    def restore_console(self):
        if self._uart:
            self._set_uart(*self._uart)
            self._uart = None

    def read_ram(self, addr, length):
        out = bytearray()
        pos = addr
        while pos < addr + length:
            n = min(self.md_chunk, addr + length - pos)
            data = parse_md(self.cmd(f"md.l 0x{pos:x} 0x{n // 4:x}"), pos, n)
            if data is None:
                if self.md_chunk <= 0x30:
                    raise LinkError(f"cannot parse md.l output at 0x{pos:x}")
                self.md_chunk -= 0x10
                continue
            out += data
            pos += n
        return bytes(out)

    def bad_blocks(self):
        if self._bad is None:
            out = self.cmd("nand bad", timeout=30)
            _, sep, rest = out.partition("bad blocks:")
            if not sep:
                raise LinkError(f"cannot read the bad block list (truncated?): {out!r}")
            self._bad = {int(x, 16) for x in re.findall(r"^\s*([0-9a-fA-F]{8})\s*$", rest, re.M)}
        return self._bad

    def good_blocks(self, part):
        off, size = PARTITIONS[part]
        bad = self.bad_blocks()
        return [b for b in range(off, off + size, BLOCK) if b not in bad]


def contiguous_runs(blocks, limit):
    """Split a list of physical block offsets into gap-free runs of at most `limit` blocks."""
    i = 0
    while i < len(blocks):
        j = i + 1
        while j < len(blocks) and j - i < limit and blocks[j] == blocks[j - 1] + BLOCK:
            j += 1
        yield i, j
        i = j


def flash_partition(link, part, data):
    off, size = PARTITIONS[part]
    good = link.good_blocks(part)
    need = -(-len(data) // BLOCK)
    if need > len(good):
        raise LinkError(f"{part}: {human(len(data))} does not fit in {len(good)} good blocks")
    data += b"\xff" * (-len(data) % PAGE)
    print(f"{part}: erasing 0x{off:07x}..0x{off + size - 1:07x}")
    link.cmd(f"nand erase 0x{off:x} 0x{size:x}", timeout=120)
    t0, done = time.monotonic(), 0
    for i, j in contiguous_runs(good[:need], CHUNK_BLOCKS):
        piece, phys = data[i * BLOCK:j * BLOCK], good[i]
        link.upload(RAM_A, piece)
        link.cmd(f"nand write 0x{RAM_A:x} 0x{phys:x} 0x{len(piece):x}", timeout=120)
        link.cmd(f"nand read 0x{RAM_B:x} 0x{phys:x} 0x{len(piece):x}", timeout=120)
        if link.crc32(RAM_B, len(piece)) != zlib.crc32(piece):
            raise LinkError(f"{part}: read-back mismatch at 0x{phys:x}")
        done += len(piece)
        progress(f"{part} write+verify", done, len(data), t0)
    print()


def read_block(link, addr):
    if link.crc32(addr, BLOCK) == FF_BLOCK_CRC:
        return b"\xff" * BLOCK
    out = bytearray()
    for p in range(addr, addr + BLOCK, PAGE):
        crc = link.crc32(p, PAGE)
        page = b"\xff" * PAGE if crc == FF_PAGE_CRC else link.read_ram(p, PAGE)
        if zlib.crc32(page) != crc:
            raise LinkError(f"page at RAM 0x{p:x} came back with a wrong CRC")
        out += page
    return bytes(out)


def dump_partition(link, part, path):
    size = PARTITIONS[part][1]
    good = link.good_blocks(part)
    if len(good) < size // BLOCK:
        print(f"{part}: skipping {size // BLOCK - len(good)} bad block(s), same as nand read does")
    t0 = time.monotonic()
    with open(path, "wb") as f:
        for n, phys in enumerate(good, 1):
            link.cmd(f"nand read 0x{RAM_A:x} 0x{phys:x} 0x{BLOCK:x}", timeout=60)
            f.write(read_block(link, RAM_A))
            progress(part, n * BLOCK, len(good) * BLOCK, t0)
    print(f"\n  -> {path}")


def bsel_record(bank):
    return b"BSEL" + bytes([bank, bank ^ 0xFF]) + BSEL_TRAILER


def sel_records(link):
    """Bank recorded in each good sel block (None = no valid record)."""
    recs = []
    for phys in link.good_blocks("sel"):
        link.cmd(f"nand read 0x{RAM_B:x} 0x{phys:x} 0x{PAGE:x}")
        rec = link.read_ram(RAM_B, 16)[:10]
        recs.append((phys, next((b for b in (0, 1) if rec == bsel_record(b)), None)))
    return recs


def first_valid(recs):
    """The first valid record wins, as in fpvboot and openipc-bsel."""
    return next((b for _, b in recs if b is not None), None)


def read_sel(link):
    return first_valid(sel_records(link))


def show_sel(link):
    recs = sel_records(link)
    bank = first_valid(recs)
    if bank is None:
        print("boot bank: no valid sel record -> fpvboot falls back to bank 0")
    else:
        print(f"boot bank: {bank}")
    if len({b for _, b in recs}) > 1:
        print("warning: sel blocks disagree:",
              ", ".join(f"0x{p:07x}={'-' if b is None else b}" for p, b in recs))


def write_sel(link, bank):
    link.upload(RAM_A, bsel_record(bank) + b"\xff" * (PAGE - 10))
    for phys in link.good_blocks("sel"):
        link.cmd(f"nand erase 0x{phys:x} 0x{BLOCK:x}")
        link.cmd(f"nand write 0x{RAM_A:x} 0x{phys:x} 0x{PAGE:x}")
    if any(b != bank for _, b in sel_records(link)):
        raise LinkError("sel record did not read back")
    print(f"boot bank is now {bank}")


def load_asw(path):
    d = Path(path).read_bytes()
    if len(d) < 0x80 or struct.unpack_from("<I", d)[0] != ASW_MAGIC:
        sys.exit(f"{path}: not an ASW image")
    if zlib.crc32(d[0x80:]) != struct.unpack_from("<I", d, 0x70)[0]:
        sys.exit(f"{path}: CRC mismatch -- truncated or corrupt file")
    offs = [struct.unpack_from("<I", d, 20 + 12 * i + 8)[0] for i in range(5)]
    return [d[a:b] for a, b in zip(offs, offs[1:] + [len(d)])]


def ubifs_space_fixup(data):
    """Space-fixup flag of each UBIFS superblock node found in a UBI image."""
    flags = []
    i = data.find(UBIFS_MAGIC)
    while i >= 0:
        if i % 8 == 0 and i + 32 <= len(data) and data[i + 20] == UBIFS_SB_NODE:
            flags.append(bool(struct.unpack_from("<I", data, i + 28)[0] & UBIFS_FLG_SPACE_FIXUP))
        i = data.find(UBIFS_MAGIC, i + 1)
    return flags


def image_problems(part, data):
    kind = part.rstrip("01")
    if kind == "kernel" and data[:4] != FIT_MAGIC:
        return ["does not look like a FIT image (fitImage)"]
    if kind in ("rootfs", "usrdata"):
        if data[:4] != b"UBI#":
            return ["does not look like a UBI image"]
        fixup = ubifs_space_fixup(data)
        if not fixup:
            return ["no UBIFS superblock found"]
        if not all(fixup):
            return ["UBIFS built without space fixup (mkfs.ubifs -F); fmc100 NAND corrupts it later"]
    return []


def build_jobs(args):
    jobs = []
    for spec in args.jobs:
        part, sep, file = spec.partition("=")
        if not sep:
            sys.exit(f"expected PART=FILE, got '{spec}'")
        jobs.append((part, file, Path(file).read_bytes()))
    if args.images or args.asw:
        if args.bank is None:
            sys.exit("--images/--asw need --bank 0 or --bank 1")
        if args.asw:
            slots = load_asw(args.asw)
            for slot, kind in ((2, "kernel"), (3, "rootfs"), (4, "usrdata")):
                jobs.append((f"{kind}{args.bank}", f"{args.asw}[slot {slot}]", slots[slot]))
        if args.images:
            for name, kind in (("fitImage", "kernel"), ("rootfs.ubi", "rootfs"),
                               ("usrdata.ubi", "usrdata")):
                f = Path(args.images) / name
                if f.exists():
                    jobs.append((f"{kind}{args.bank}", str(f), f.read_bytes()))
    if not jobs:
        sys.exit("nothing to flash")

    seen = set()
    for part, src, data in jobs:
        if part not in PARTITIONS:
            sys.exit(f"unknown partition '{part}' (see: usbburn.py partitions)")
        if part in seen:
            sys.exit(f"{part} given twice")
        seen.add(part)
        if part in PROTECTED and not args.force:
            sys.exit(f"{part} is protected (boot/env/sel/factory) -- add --force if you mean it")
        if len(data) > PARTITIONS[part][1]:
            sys.exit(f"{src}: {human(len(data))} is larger than {part}")
        for problem in image_problems(part, data):
            if not args.force:
                sys.exit(f"{src} -> {part}: {problem} (--force to flash anyway)")
            print(f"warning: {src} -> {part}: {problem}")

    banks = {p[-1] for p, _, _ in jobs if p[-1] in "01"}
    if args.bank is not None and banks - {str(args.bank)}:
        sys.exit(f"--bank {args.bank} but the partitions target bank(s) {sorted(banks)}")
    bank = args.bank if args.bank is not None else (int(min(banks)) if len(banks) == 1 else None)
    if (args.select or args.boot) and bank is None:
        sys.exit("--select/--boot need the jobs to target a single bank")
    return jobs, bank


def do_flash(link, args, jobs, bank):
    current = read_sel(link)
    boots = 0 if current is None else current
    print(f"sel: device boots bank {boots}" + (" (no valid record)" if current is None else ""))
    if bank == boots:
        print("note: flashing the bank that boots -- if this is interrupted, it won't boot until"
              " reflashed (USB recovery still works)")
    for part, src, data in jobs:
        print(f"{part} <- {src} ({human(len(data))})")
        flash_partition(link, part, data)
    if args.select and bank != current:
        write_sel(link, bank)
    elif bank is not None and bank != boots and not args.boot:
        print(f"note: bank {bank} flashed, but the device still boots bank {boots}"
              f" -- run 'usbburn.py select {bank}' or pass --select")
    if args.boot:
        print(f"booting bank {bank} (fpvboot {bank}) ...")
        link.fire(f"fpvboot {bank}")


def do_shell(link):
    print("U-Boot over USB. Only the last ~400 bytes of output come back. 'exit' quits.")
    while True:
        try:
            line = input("usb> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if line in ("exit", "quit"):
            return
        if not line:
            continue
        if line.split()[0] in NO_RETURN:
            link.fire(line)
            print("sent -- the device leaves download mode")
            return
        ok, out = link.run(line, timeout=120)
        if out.strip():
            print(out.rstrip())
        if not ok:
            print("[ERROR] -- re-arming the link ...")
            reason = link.recover()
            print(reason or "(no output)")


def do_info(link):
    print(link.cmd("version").strip())
    bad = sorted(link.bad_blocks())
    print("bad blocks:", ", ".join(f"0x{b:07x}" for b in bad) or "none")
    show_sel(link)


def print_partitions():
    print(f"{'mtd':<5}{'name':<10}{'offset':<12}{'size':<10}")
    for n, (name, (off, size)) in enumerate(PARTITIONS.items()):
        note = "  protected" if name in PROTECTED else ""
        print(f"mtd{n:<2}{name:<10}0x{off:07x}   {human(size):<10}{note}")


def main():
    ap = argparse.ArgumentParser(
        description="Flash, back up and recover the Ascent air unit over USB (U-Boot download"
                    " mode: hold bind while powering on).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="examples:\n"
               "  usbburn.py info\n"
               "  usbburn.py dump all -o backup/\n"
               "  usbburn.py flash --bank 1 --images openipc/output/images --select --boot\n"
               "  usbburn.py flash --bank 0 --asw Ascent_H_Sky_18_21_10_OpenIPC.img\n"
               "  usbburn.py flash kernel0=fitImage\n"
               "  usbburn.py select          # show the boot bank\n"
               "  usbburn.py select 0        # boot bank 0 from now on\n\n"
               "udev rule (/etc/udev/rules.d/82-hisilicon-usbburn.rules):\n"
               '  SUBSYSTEM=="usb", ATTR{idVendor}=="3361", ATTR{idProduct}=="d001", MODE="0666"')
    ap.add_argument("--wait", type=float, default=30, metavar="S",
                    help="seconds to wait for the device (default 30)")
    sub = ap.add_subparsers(dest="action", required=True)
    sub.add_parser("partitions", help="print the NAND layout (no device needed)")
    sub.add_parser("info", help="U-Boot version, bad blocks, boot bank")
    sub.add_parser("shell", help="interactive U-Boot console")
    p = sub.add_parser("cmd", help="run one U-Boot command")
    p.add_argument("command", nargs="+")
    p = sub.add_parser("dump", help="back up partitions (bad blocks skipped, like nand read)")
    p.add_argument("parts", nargs="+", metavar="PART", help="partition names, or 'all'")
    p.add_argument("-o", "--outdir", help="output directory (default ascent-dump-<time>)")
    p = sub.add_parser("flash", help="erase, write and verify partitions")
    p.add_argument("jobs", nargs="*", metavar="PART=FILE")
    p.add_argument("--bank", type=int, choices=(0, 1))
    p.add_argument("--images", metavar="DIR",
                   help="fitImage, rootfs.ubi, usrdata.ubi from a build's output/images")
    p.add_argument("--asw", metavar="IMG", help="Ascent_H_Sky_*.img (kernel, rootfs, usrdata)")
    p.add_argument("--select", action="store_true",
                   help="after verifying, make the flashed bank the boot bank")
    p.add_argument("--boot", action="store_true", help="boot the flashed bank (fpvboot N)")
    p.add_argument("--force", action="store_true",
                   help="allow protected partitions and images that fail the sanity checks")
    p = sub.add_parser("select", help="show the boot bank (sel partition), or set it")
    p.add_argument("bank", type=int, nargs="?", choices=(0, 1))
    p = sub.add_parser("boot", help="boot now via the stock fpvboot")
    p.add_argument("bank", nargs="?", default="auto", choices=("0", "1", "auto"))
    sub.add_parser("reset", help="reboot the device")
    args = ap.parse_args()

    if args.action == "partitions":
        print_partitions()
        return
    if args.action == "flash":
        jobs, bank = build_jobs(args)
    if args.action == "dump":
        parts = list(PARTITIONS) if "all" in args.parts else args.parts
        for part in parts:
            if part not in PARTITIONS:
                sys.exit(f"unknown partition '{part}' (see: usbburn.py partitions)")

    link = Link(find_device(args.wait))
    try:
        link.handshake()
        if args.action in ("info", "dump", "flash", "select"):
            link.fast_console()
        if args.action == "info":
            do_info(link)
        elif args.action == "shell":
            do_shell(link)
        elif args.action == "cmd":
            command = " ".join(args.command)
            if args.command[0] in NO_RETURN:
                link.fire(command)
            else:
                print(link.cmd(command, timeout=120).rstrip())
        elif args.action == "dump":
            outdir = Path(args.outdir or time.strftime("ascent-dump-%Y%m%d-%H%M%S"))
            outdir.mkdir(parents=True, exist_ok=True)
            bad = sorted(link.bad_blocks())
            (outdir / "badblocks.txt").write_text("".join(f"0x{b:07x}\n" for b in bad))
            for part in parts:
                dump_partition(link, part, outdir / f"{part}.bin")
        elif args.action == "flash":
            do_flash(link, args, jobs, bank)
        elif args.action == "select" and args.bank is None:
            show_sel(link)
        elif args.action == "select":
            write_sel(link, args.bank)
        elif args.action == "boot":
            link.fire(f"fpvboot {args.bank}")
        elif args.action == "reset":
            link.fire("reset")
        link.restore_console()
    except LinkError as e:
        sys.exit(f"error: {e}")
    except KeyboardInterrupt:
        sys.exit("\ninterrupted -- if that was during an upload, power-cycle the device")


if __name__ == "__main__":
    main()
