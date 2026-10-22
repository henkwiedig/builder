#!/usr/bin/env python3
"""
Flash a BetaFPV P1 SKY (Artosyn PROXIMA 9311) through its stock U-Boot's USB
upgrade -- no SSH, no pins, no RAM boot -- with any update image in BetaFPV's
format: their P1_SKY_*.img, or this build's P1_SKY_*_OpenIPC_*.img.

  ar9311-usbburn.py flash IMAGE [--from-stock [TTY]]
  ar9311-usbburn.py info IMAGE

Getting there: the stock firmware reboots into U-Boot's upgrade mode on a
10-byte command over its USB serial gadget (--from-stock sends it, default
/dev/ttyACM0 at 1152000 baud). U-Boot then enumerates as 1d6b:0100 "USB
download gadget" (HID) and takes one image. An installed OpenIPC does not
answer that command; "openipc-bsel switch" (or set) to a slot with stock and
a power cycle get there.

What U-Boot does with the image (seen on the air unit, stock U-Boot of
v2.0.5): it checks the RSA signature but does not enforce it ("signature
verification fail", then "Verify upgrade image success"), so OpenIPC images
go in too. It writes the slot that is not active -- env, uboot, kernel, dtb,
userapp (ubiformat, bad blocks skipped), plus the shared vendor partition --
rewrites all four SPL copies from the image's loader and both GPT copies,
making that slot the active one, verifies, and asks for a reset. Nothing
carries over: an OpenIPC slot comes up fresh (set root's password with one
ssh login). The upload runs at about 27 KiB/s (28 bytes per HID report, one
report per USB frame): ~7 min for an OpenIPC image, ~15 for a stock one.

Protocol (reversed from the U-Boot binary; the packet layout is Henk Wiedig's
FreeArtLynk usbflasher.py): every HID report starts with a 36-byte header --
magic FF 55 FF AA "ARTO", +0x10 u32 inner size (<= 64, U-Boot's MTU), +0x14
u32 chunk count, +0x18 u32 chunk index, +0x1c sub-protocol 1 -- and the first
chunk of a message then a 12-byte inner header (u16 port 0, u16 header length
12, u32 payload size). The start command is one 56-byte message, "upgd" + the
image size; the image is one message of 64-byte reports, 16 bytes of it in the
first and 28 in every following one. U-Boot answers in the same framing with
text: "Upgrade_status: <state> percent <n>", "upgrade_complete",
"upgrade_failed: ret = <n>".

Access: /dev/hidrawN for 1d6b:0100 (and the serial gadget for --from-stock),
e.g. /etc/udev/rules.d/80-artosyn.rules:
  SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1d6b", ATTRS{idProduct}=="0100", MODE="0660", GROUP="plugdev"
"""
import argparse
import glob
import hashlib
import math
import os
import re
import select
import struct
import sys
import time

VID_PID = "00001D6B:00000100"
REBOOT_CMD = b"\xAA\x05\x00\x1D\x00\x00\xCC\xEB\xAA\x00"
SERIAL_BAUD = 1152000
IMAGE_MAGIC = 0x4152544F

MAGIC = bytes([0xFF, 0x55, 0xFF, 0xAA]) + b"ARTO"
MTU = 64
OUTER = 36
INNER = 12
FIRST = MTU - OUTER - INNER     # image bytes in the first report
CONT = MTU - OUTER              # image bytes in every following one


def outer(inner_size, chunks, index):
    h = bytearray(OUTER)
    h[0:8] = MAGIC
    struct.pack_into("<III", h, 0x10, inner_size, chunks, index)
    h[0x1C] = 1
    return h


def start_cmd(size):
    cmd = b"upgd" + struct.pack("<I", size)
    return bytes(outer(INNER + len(cmd), 1, 0) + struct.pack("<HHI4x", 0, INNER, len(cmd)) + cmd)


def data_reports(image):
    """The image as one message: 64-byte reports."""
    chunks = math.ceil((INNER + len(image)) / CONT)
    first = image[:FIRST]
    yield bytes((outer(INNER + len(first), chunks, 0) + struct.pack("<HHI4x", 0, INNER, len(image))
                 + first).ljust(MTU, b"\0"))
    for i, pos in enumerate(range(FIRST, len(image), CONT), 1):
        yield bytes((outer(CONT, chunks, i) + image[pos:pos + CONT]).ljust(MTU, b"\0"))


def check_image(data):
    """(product, customer, signed) after checking what U-Boot needs."""
    if len(data) < 0x220 or struct.unpack_from("<I", data, 0)[0] != IMAGE_MAGIC:
        sys.exit("not an ARTO update image")
    hext = struct.unpack_from("<H", data, 8)[0]
    body = 0x100 + hext + 0x120
    if hashlib.sha256(data[body:]).digest() != data[0x100 + hext:0x100 + hext + 32]:
        sys.exit("SHA-256 mismatch: damaged or truncated")
    if data[6] != 2:
        sys.exit(f"flash type {data[6]}, not NAND")
    product = data[0x80:0xc0].split(b"\0")[0].decode(errors="replace")
    if product != "P1_SKY":
        sys.exit(f"product {product!r}, not P1_SKY")
    customer = data[0x2c:0x40].split(b"\0")[0].decode(errors="replace")
    return product, customer, any(data[0x100 + hext + 32:body])


class Gadget:
    """U-Boot's upgrade gadget through /dev/hidrawN."""

    def __init__(self, timeout):
        deadline = time.time() + timeout
        self.fd = None
        while self.fd is None:
            for uevent in glob.glob("/sys/class/hidraw/hidraw*/device/uevent"):
                if f"HID_ID=0003:{VID_PID}" in open(uevent).read():
                    dev = "/dev/" + uevent.split("/")[4]
                    try:
                        self.fd = os.open(dev, os.O_RDWR)
                    except PermissionError:
                        sys.exit(f"{dev}: permission denied (udev rule, see --help)")
                    print(f"U-Boot upgrade gadget at {dev}")
                    break
            else:
                if time.time() > deadline:
                    sys.exit("no 1d6b:0100 (U-Boot's upgrade mode) appeared")
                time.sleep(0.5)
        self.text = bytearray()
        self.messages = []

    def write(self, report):
        os.write(self.fd, b"\0" + report)   # report ID 0, stripped by the kernel

    def poll(self, timeout=0.0):
        """Reads what U-Boot sent; returns the messages completed."""
        done = []
        while select.select([self.fd], [], [], timeout)[0]:
            timeout = 0
            raw = os.read(self.fd, MTU)
            if len(raw) < OUTER:
                continue
            chunks, index = struct.unpack_from("<II", raw, 0x14)
            if index == 0:
                self.text = bytearray(raw[OUTER + INNER:])
            else:
                self.text += raw[OUTER:]
            if index + 1 >= chunks:
                msg = self.text.split(b"\0")[0].decode(errors="replace").strip()
                if msg:
                    done.append(msg)
        return done


def report(msgs, state):
    for m in msgs:
        p = re.search(r"percent\D*(\d+)", m)
        if p:
            if p.group(1) != state.get("pct"):
                state["pct"] = p.group(1)
                print(f"\n  U-Boot: writing, {p.group(1)}%", end="", flush=True)
        else:
            print(f"\n  U-Boot: {m}", end="", flush=True)
        if "upgrade_complete" in m:
            state["result"] = True
        elif "upgrade_failed" in m:
            state["result"] = False


def cmd_flash(a):
    data = open(a.image, "rb").read()
    product, customer, signed = check_image(data)
    print(f"{os.path.basename(a.image)}: {product}, customer {customer!r}, "
          f"{'signed' if signed else 'unsigned'}, {len(data)} bytes")
    if a.from_stock:
        try:
            import serial
        except ImportError:
            sys.exit("--from-stock needs pyserial")
        with serial.Serial(a.from_stock, SERIAL_BAUD, timeout=1) as s:
            s.write(REBOOT_CMD)
        print(f"sent the upgrade command on {a.from_stock}")
    g = Gadget(a.timeout)
    state = {}

    g.write(start_cmd(len(data)))
    report(g.poll(0.5), state)
    total = math.ceil((INNER + len(data)) / CONT)
    t0 = time.time()
    for i, r in enumerate(data_reports(data)):
        g.write(r)
        if i % 256 == 0:
            report(g.poll(), state)
            sent = min(len(data), FIRST + i * CONT)
            rate = sent / max(time.time() - t0, 1e-3)
            print(f"\r  uploading {sent * 100 // len(data):3d}%  {rate / 1024:5.1f} KiB/s  "
                  f"{(len(data) - sent) / rate / 60:4.1f} min left ", end="", flush=True)
    print(f"\r  uploaded {len(data)} bytes in {(time.time() - t0) / 60:.1f} min" + " " * 20, end="")

    deadline = time.time() + a.write_timeout
    while state.get("result") is None and time.time() < deadline:
        try:
            report(g.poll(1.0), state)
        except OSError:
            break   # gadget gone: U-Boot finished and reset
    print()
    if state.get("result") is False:
        sys.exit("U-Boot reports the upgrade failed; the active slot is unchanged")
    if state.get("result") is None:
        print("no completion message from U-Boot; check its serial console before resetting")
    else:
        print("done: power-cycle the board, it boots the slot just written")


def cmd_info(a):
    data = open(a.image, "rb").read()
    product, customer, signed = check_image(data)
    print(f"{product}, customer {customer!r}, {'signed' if signed else 'unsigned'}, "
          f"{len(data)} bytes, ~{len(data) / 27.5 / 1024 / 60:.0f} min upload")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("flash", help="flash an update image through U-Boot's USB upgrade")
    p.add_argument("image", help="P1_SKY_*.img (stock) or P1_SKY_*_OpenIPC_*.img")
    p.add_argument("--from-stock", nargs="?", const="/dev/ttyACM0", metavar="TTY",
                   help="send stock's upgrade command first (default /dev/ttyACM0)")
    p.add_argument("--timeout", type=float, default=60, help="seconds to wait for the gadget")
    p.add_argument("--write-timeout", type=float, default=600,
                   help="seconds to wait for U-Boot's write after the upload")
    p.set_defaults(fn=cmd_flash)
    p = sub.add_parser("info", help="check an image as flash would")
    p.add_argument("image")
    p.set_defaults(fn=cmd_info)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
