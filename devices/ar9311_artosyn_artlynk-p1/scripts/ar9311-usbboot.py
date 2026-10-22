#!/usr/bin/env python3
"""
RAM-boot a BetaFPV P1 / Artosyn PROXIMA 9311 (AR9311) over USB -- no flash
needed. Nothing is written to the board's NAND.

  ar9311-usbboot.py linux  [--images DIR] [--serial TTY [--root-password PW]]
      patched stock SPL + U-Boot, then the ar9311_artosyn_artlynk-p1 build's
      kernel/initramfs/dtb; U-Boot autoboots them (no UART needed), --serial
      shows the boot log
  ar9311-usbboot.py linux --nand-root ...
      kernel/dtb only, root on the rootfs flashed to userapp1 (slot B): proves
      a slot-B install boots before it is made the active slot
  ar9311-usbboot.py uboot  [--images DIR]      stop at the stock U-Boot
  ar9311-usbboot.py spl    <loader.bin>        just run an IMGI loader

The board has to be in its mask-ROM USB mode (enumerates as 5343:0200
"SCA200 usb gadget"): with no bootable flash it lands there on power-up.
Host needs pyusb (+ pyserial for --serial / the uboot command) and access to
the USB device (udev rule for 5343:0200, e.g. MODE="0660", GROUP="plugdev").
The serial console is /dev/ttyUSB0 at 1152000 baud; nothing else may hold it.

The stock blobs (loader.bin, vendor.img, uboot0.img) come from the build's
output/images/artlynk-p1/, extracted from the stock P1 image by
package/artlynk-p1-vendor-firmware.


Mask-ROM USB download protocol (reversed from the bootrom)
----------------------------------------------------------
One request only: vendor control OUT, bmRequestType 0x40, bRequest 0x0C,
wLength <= 0x1000. Payload "US" | u16 len | u64 addr | data[len] is a plain
memcpy(addr, data) (len 4 on an aligned address: one 32-bit store). len 0 or
addr 0 leaves the download loop; the ROM then checks the IMGI header at
0x100040 (magic 0x494d4711, header size <= 0x200, u32 word-sum header
checksum at +0x08, load address/size at +0x18/+0x1c inside 0x110000..0x200000,
u64 word-sum payload checksum at +0x34), stores the boot source at 0x100054
(0x40 = USB) and jumps to the load address. After power-on and after being
re-entered the ROM enumerates, drops off and enumerates again, so a session
is retried on the next instance if the device vanishes mid-transfer.

Getting DDR up without flash
----------------------------
The stock SPL (loader.bin v2.0.5) has a USB path: booted from USB it copies
an OTRA+uImage U-Boot from DDR (address in reg 0x0a10613c) to its entry and
jumps -- but never trains DDR, and training needs PHY firmware read from the
SPI-NAND "vendor" partition. So the SPL is patched:

  0x110720  bl stub ; b 0x1104f0   (USB path) run the stub, then copy+jump
  0x111478  mov x0,#FAKE_DEV ; ret  get-spinand-device -> fake struct in SRAM
  0x111918  b vread                 spinand_flash_read -> memcpy from SRAM
  stub (appended at 0x131960): snapshot 0x101000..0x102120 (the ROM's state,
  which overlaps the SPL's BSS), zero it, dram_init() -- DDR training from
  a virtual flash (GPT + vendor.img at 0x180000) --, restore the snapshot,
  call the ROM's own usb_download(0) at 0x52f8 (x18 = gd saved around it)
  for a second session straight into DDR, return into the USB path.

The stock U-Boot rejects a raw `booti`; the kernel goes as the build's
uImage.ar9311 (OTRA + LZ4 legacy uImage, see board/ar9311/post-image.sh) and
boots with `bootm kernel initrd:size dtb`. Load map (MissingLynk's air unit
device.mk): kernel 0x21800000, initrd 0x23000000, dtb 0x24800000, all below
U-Boot's HID upgrade buffer at 0x24900000; initrd_high/fdt_high keep U-Boot
from moving them into the kernel's isp-cma region.

Autoboot without a console
--------------------------
For `linux` the U-Boot image is patched before it is sent (the SPL's USB path
checks no CRC; the uImage CRCs and the OTRA sum are fixed up anyway):

  0x2001a790  nop     booted from USB (0x100056 == 0x40) U-Boot calls
                      usb_booting() (HID upgrade loop) -- skip it, as a
                      Ctrl-C on the console would
  default env         bootcmd = setenv initrd_high/fdt_high; bootm ...,
                      bootargs, bootdelay=0 -- rewritten in place (no flash:
                      U-Boot runs on its default env)
"""
import argparse
import os
import struct
import sys
import time
import uuid
import zlib

import usb.core
import usb.util

BUILDER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../.."))
DEFAULT_IMAGES = os.path.join(BUILDER, "openipc/output/images")

# ---------------------------------------------------------------- ROM protocol

ROM_VID, ROM_PID = 0x5343, 0x0200
MAX_XFER = 0x1000
HDR_ADDR = 0x100040


def find_rom(timeout=10.0, not_addr=None, settle=0.5):
    """Wait for a stable ROM device; not_addr=(bus, address) skips a stale instance."""
    end = time.time() + timeout
    while time.time() < end:
        dev = usb.core.find(idVendor=ROM_VID, idProduct=ROM_PID)
        if dev is not None and settle:
            time.sleep(settle)
            again = usb.core.find(idVendor=ROM_VID, idProduct=ROM_PID)
            if again is None or (again.bus, again.address) != (dev.bus, dev.address):
                continue
        if dev is not None and (not_addr is None or (dev.bus, dev.address) != not_addr):
            try:
                if dev.is_kernel_driver_active(0):
                    dev.detach_kernel_driver(0)
            except Exception:
                pass
            try:
                dev.set_configuration()
            except usb.core.USBError:
                pass
            return dev
        time.sleep(0.1)
    return None


def _pkt(addr, data):
    return b"US" + struct.pack("<HQ", len(data), addr) + data


def write_mem(dev, addr, data, label):
    step = MAX_XFER - 12
    t0 = time.time()
    for off in range(0, len(data), step):
        dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(addr + off, data[off:off + step]), timeout=5000)
    rate = len(data) / max(time.time() - t0, 1e-3) / 1024
    print(f"  {label:10s} {addr:#010x} {len(data):8d} B  {rate:6.0f} KiB/s")


def run_session(writes, timeout, not_addr=None, regs=()):
    """Feed one ROM download session and start it; returns the device's (bus, addr)."""
    skip = not_addr
    for _ in range(4):
        dev = find_rom(timeout=timeout, not_addr=skip)
        if dev is None:
            sys.exit("ROM device 5343:0200 not found - power-cycle the board / check the serial log")
        where = (dev.bus, dev.address)
        try:
            for addr, data, label in writes:
                write_mem(dev, addr, data, label)
            for addr, value in regs:
                dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(addr, struct.pack("<I", value)), timeout=5000)
        except usb.core.USBError as e:
            print(f"  ROM device dropped off ({e}), retrying on its next enumeration")
            usb.util.dispose_resources(dev)
            skip = where
            continue
        try:
            dev.ctrl_transfer(0x40, 0x0C, 0, 0, _pkt(0, b""), timeout=2000)
        except usb.core.USBError:
            pass  # the ROM may jump before completing the status stage
        usb.util.dispose_resources(dev)
        return where
    sys.exit("ROM device kept dropping off")

# ---------------------------------------------------------------- IMGI loader header

IMGI_MAGIC = 0x494D4711


def imgi_header(load_addr, payload, hdr_size=0x40, version=1):
    if len(payload) % 8:
        payload += b"\0" * (8 - len(payload) % 8)
    h = bytearray(hdr_size)
    struct.pack_into("<IHH", h, 0, IMGI_MAGIC, version, hdr_size)
    struct.pack_into("<II", h, 0x18, load_addr, len(payload))
    struct.pack_into("<Q", h, 0x34, sum(struct.unpack(f"<{len(payload) // 8}Q", payload)) & (2**64 - 1))
    struct.pack_into("<I", h, 0x08, sum(struct.unpack(f"<{hdr_size // 4}I", h)) & 0xFFFFFFFF)
    return bytes(h), payload


def parse_loader(path):
    """(header, payload, load_addr) of a stock loader.bin (payload at file offset 0x200)."""
    d = open(path, "rb").read()
    magic, _ver, hs = struct.unpack_from("<IHH", d, 0)
    if magic != IMGI_MAGIC:
        sys.exit(f"{path}: not an IMGI loader")
    load, size = struct.unpack_from("<II", d, 0x18)
    poff = (hs + 0x1FF) & ~0x1FF
    return d[:hs], d[poff:poff + size], load

# ---------------------------------------------------------------- SPL patch + virtual flash

SPL_LOAD, SPL_SIZE = 0x110000, 0x21960
VFLASH_BASE, VFLASH_SIZE = 0x180000, 0x7E000
FAKE_DEV = 0x1FF800
ERASE_SIZE = 0x20000
VENDOR_OFF = 0x10000          # LBA 0x80
UBOOT_PTR_REG = 0x0A10613C

# appended at 0x131960; assembled with keystone, checked with capstone
SPL_STUB = bytes.fromhex(
    "fd7bbea9fd030091000082d20002a0f201009cd2e103a0f2022482d2038440f8238400f8422000f1"
    "a1ffff54000082d20002a0f2022482d21f8400f8422000f1c1ffff54dd79ff9700009cd2e003a0f2"
    "010082d20102a0f2022482d2038440f8238400f8422000f1a1ffff54f20b00f900008052494efb97"
    "f20b40f9fd7bc2a8c0035fd6e103012ae203022a2400028b05009cd2e500a0f29f0005eb68010054"
    "050080d20503a0f22100058ba20000b42614403866140038420400d1fcffff1700008052c0035fd6"
    "80008012c0035fd6")

SPL_PATCHES = {  # addr: (original, patched)
    0x110720: ("2e1e00940400a8d2", "9084009473ffff17"),
    0x111478: ("fd7bbfa9fd0300914e350094", "00009fd2e003a0f2c0035fd6"),
    0x111918: ("fd7bbba9", "33800014"),
}


def patch_spl(payload):
    if len(payload) != SPL_SIZE:
        sys.exit(f"SPL size {len(payload):#x}, the patch is for the v2.0.5 SPL ({SPL_SIZE:#x})")
    p = bytearray(payload)
    for addr, (orig, new) in SPL_PATCHES.items():
        o, orig, new = addr - SPL_LOAD, bytes.fromhex(orig), bytes.fromhex(new)
        if p[o:o + len(orig)] != orig:
            sys.exit(f"SPL bytes at {addr:#x} differ: not the v2.0.5 SPL")
        p[o:o + len(new)] = new
    return bytes(p) + SPL_STUB


def build_gpt(name, first_lba, n_lbas):
    """LBA0 protective MBR, LBA1 header, LBA2.. entries; one partition, attribute bit 47."""
    ent = bytearray(128 * 128)
    e = bytearray(128)
    e[0:16] = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
    e[16:32] = uuid.uuid4().bytes_le
    struct.pack_into("<QQQ", e, 32, first_lba, first_lba + n_lbas - 1, 1 << 47)
    e[56:56 + 72] = name.encode("utf-16-le").ljust(72, b"\0")
    ent[0:128] = e
    last = 0x3FF
    h = bytearray(0x5C)
    struct.pack_into("<8sII", h, 0, b"EFI PART", 0x10000, 0x5C)
    struct.pack_into("<QQQQ", h, 0x18, 1, last, 34, last - 33)
    h[0x38:0x48] = uuid.uuid4().bytes_le
    struct.pack_into("<QIII", h, 0x48, 2, 128, 128, zlib.crc32(ent))
    struct.pack_into("<I", h, 0x10, zlib.crc32(h))
    mbr = bytearray(512)
    mbr[446 + 4] = 0xEE
    struct.pack_into("<II", mbr, 446 + 8, 1, last)
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr) + bytes(h).ljust(512, b"\0") + bytes(ent)


def build_vflash(vendor):
    """GPT @0, vendor.img @VENDOR_OFF, zeros where the SPL looks for GPT copy 1."""
    v = bytearray(max(VENDOR_OFF + len(vendor), 2 * ERASE_SIZE + 0x4400))
    gpt = build_gpt("vendor", VENDOR_OFF // 512, (len(vendor) + 511) // 512)
    v[0:len(gpt)] = gpt
    v[VENDOR_OFF:VENDOR_OFF + len(vendor)] = vendor
    assert len(v) <= VFLASH_SIZE
    return bytes(v)


def fake_dev():
    """The two fields the SPL's GPT code reads: +0x10 erase size, +0x14 GPT start LBA."""
    d = bytearray(0x40)
    struct.pack_into("<II", d, 0x10, ERASE_SIZE, 0)
    return bytes(d)

# ---------------------------------------------------------------- U-Boot serial console

class UBoot:
    PROMPT = b"=> "

    def __init__(self, port, baud=1152000):
        import serial
        self.ser = serial.Serial(port, baud, timeout=0.05)

    def read_until(self, token, timeout):
        buf = b""
        end = time.time() + timeout
        while time.time() < end:
            d = self.ser.read(4096)
            if d:
                sys.stdout.write(d.decode(errors="replace").replace("\r", ""))
                sys.stdout.flush()
                buf += d
                if token in buf:
                    return buf
        return None

    def break_in(self, timeout=30):
        """Ctrl-C out of the HID upgrade mode and the autoboot countdown."""
        end = time.time() + timeout
        while time.time() < end:
            self.ser.write(b"\x03")
            if self.read_until(self.PROMPT, 0.3) is not None:
                self.ser.write(b"\r")
                if self.read_until(self.PROMPT, 1) is not None:
                    return True
        return False

    def cmd(self, line, timeout=10):
        self.ser.reset_input_buffer()
        self.ser.write(line.encode() + b"\r")
        return self.read_until(self.PROMPT, timeout)

    def stream(self, seconds):
        self.read_until(b"\0never\0", seconds)

# ---------------------------------------------------------------- commands

KADDR, RDADDR, DTADDR = 0x21800000, 0x23000000, 0x24800000
RAM_BOOTARGS = "earlycon keep_bootcon console=ttyS0,1152000 root=/dev/ram0 rdinit=/init"
# As post-image.sh writes them into the dtb for the flash boot. Here ubi.mtd=18
# stays userapp1: only the SPL's flash boot rewrites it to the active slot.
NAND_BOOTARGS = "earlycon console=ttyS0,1152000 ubi.mtd=18 root=ubi0:rootfs rootfstype=ubifs ro"

# ---------------------------------------------------------------- U-Boot autoboot patch

UBOOT_TEXT = 0x20001000       # uboot0.img: OTRA 0x40 + uImage header 0x40, payload linked here
UBOOT_PAYLOAD = 0x80
UBOOT_PATCHES = {  # addr: (original, patched)
    0x2001a790: ("eaad0094", "1f2003d5"),   # bl usb_booting -> nop
}
ENV_FIRST = b"bootargs=console=ttyS0,115200"


def patch_uboot(img, env):
    """Skip the HID upgrade trap and replace entries of the built-in default env."""
    u = bytearray(img)
    for addr, (orig, new) in UBOOT_PATCHES.items():
        o, orig, new = addr - UBOOT_TEXT + UBOOT_PAYLOAD, bytes.fromhex(orig), bytes.fromhex(new)
        if u[o:o + len(orig)] != orig:
            sys.exit(f"U-Boot bytes at {addr:#x} differ: not the P1 v2.0.5 U-Boot")
        u[o:o + len(new)] = new
    start = u.find(ENV_FIRST)
    end = u.find(b"\0\0", start)
    if start < 0 or end < 0:
        sys.exit("U-Boot default environment not found")
    old = [e.split(b"=", 1) for e in bytes(u[start:end]).split(b"\0")]
    new = dict(old)
    new.update({k.encode(): v.encode() for k, v in env.items()})
    blob = b"\0".join(k + b"=" + v for k, v in new.items())
    if len(blob) > end - start:
        sys.exit(f"patched U-Boot env too long ({len(blob)} > {end - start} B)")
    u[start:end] = blob.ljust(end - start, b"\0")
    # legacy uImage header at 0x40: data CRC over the payload, then header CRC
    size = struct.unpack_from(">I", u, 0x40 + 12)[0]
    struct.pack_into(">I", u, 0x40 + 24, zlib.crc32(u[UBOOT_PAYLOAD:UBOOT_PAYLOAD + size]))
    struct.pack_into(">I", u, 0x40 + 4, 0)
    struct.pack_into(">I", u, 0x40 + 4, zlib.crc32(u[0x40:0x80]))
    # OTRA header: +0x10 uImage size, +0x20 byte sum over it
    n = struct.unpack_from("<I", u, 0x10)[0]
    struct.pack_into("<I", u, 0x20, sum(u[0x40:0x40 + n]) & 0xFFFFFFFF)
    return bytes(u)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as e:
        sys.exit(f"{path}: {e.strerror} (built ar9311_artosyn_artlynk-p1 with the stock image?)")


def cmd_spl(a):
    hdr, payload, load = parse_loader(a.loader)
    run_session([(load, payload, "spl"), (HDR_ADDR, hdr, "imgi hdr")], timeout=10)
    print("started - watch the serial console")


def boot_uboot(a, extra=(), env=None):
    """Session 1: patched SPL + virtual flash; session 2: U-Boot (+ extra) into DDR."""
    blobs = os.path.join(a.images, "artlynk-p1")
    _, payload, load = parse_loader(os.path.join(blobs, "loader.bin"))
    hdr, spl = imgi_header(load, patch_spl(payload))
    vflash = build_vflash(read(os.path.join(blobs, "vendor.img")))
    uboot = read(os.path.join(blobs, "uboot0.img"))
    if env:
        uboot = patch_uboot(uboot, env)

    print("session 1: patched SPL + virtual flash")
    old = run_session([(VFLASH_BASE, vflash, "vflash"), (FAKE_DEV, fake_dev(), "fake dev"),
                       (load, spl, "spl"), (HDR_ADDR, hdr, "imgi hdr")], timeout=10)
    print("DDR training, waiting for the ROM to come back ...")
    print("session 2: U-Boot into DDR")
    run_session([(a.uboot_addr, uboot, "u-boot"), *extra], timeout=20, not_addr=old,
                regs=[(UBOOT_PTR_REG, a.uboot_addr)])


def cmd_uboot(a):
    boot_uboot(a)
    print(f"started - U-Boot on {a.serial} at 1152000 baud (Ctrl-C twice for the prompt)")


def cmd_linux(a):
    kernel = read(os.path.join(a.images, "uImage.ar9311"))
    dtb = read(os.path.join(a.images, a.dtb))
    if kernel[:4] != b"OTRA":
        sys.exit("uImage.ar9311: not the OTRA kernel container")
    extra = [(KADDR, kernel, "kernel"), (DTADDR, dtb, "dtb")]
    if a.nand_root:
        assert KADDR + len(kernel) < DTADDR
        rd = "-"
        bootargs = a.bootargs or NAND_BOOTARGS
    else:
        initrd = read(os.path.join(a.images, "rootfs.cpio.gz"))
        assert KADDR + len(kernel) < RDADDR and RDADDR + len(initrd) < DTADDR
        extra.insert(1, (RDADDR, initrd, "initrd"))
        rd = f"{RDADDR:#x}:{len(initrd):#x}"
        bootargs = a.bootargs or RAM_BOOTARGS

    bootcmd = ("setenv initrd_high 0xffffffffffffffff; setenv fdt_high 0xffffffffffffffff; "
               f"bootm {KADDR:#x} {rd} {DTADDR:#x}")
    boot_uboot(a, extra=extra, env={"bootcmd": bootcmd, "bootargs": bootargs, "bootdelay": "0"})
    if not a.serial:
        print("started - U-Boot autoboots the kernel (--serial TTY to watch)")
        return
    # Opened only now: opening the serial port toggles DTR/RTS.
    console = UBoot(a.serial)
    if not a.root_password:
        console.stream(a.follow)
        return
    # A fresh OpenIPC is unclaimed: root has no password and its login shell
    # (openipc-claim) runs `passwd root`. An image that ships the Majestic
    # EULA asks for acceptance first -- that is for the owner to type, so
    # stop there instead.
    if console.read_until(b"login:", a.follow) is None:
        sys.exit("\nno login prompt")
    console.ser.write(b"root\r")
    if console.read_until(b"New password:", 20) is None:
        sys.exit("\nno password prompt (already claimed, or the EULA question: answer it yourself)")
    console.ser.write(a.root_password.encode() + b"\r")
    if console.read_until(b"Retype password:", 10) is None:
        sys.exit("\npasswd did not ask again")
    console.ser.write(a.root_password.encode() + b"\r")
    console.stream(5)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("spl", help="load and start an IMGI loader")
    p.add_argument("loader")
    p.set_defaults(fn=cmd_spl)

    for name, fn, help_ in (("uboot", cmd_uboot, "patched SPL, then the stock U-Boot"),
                            ("linux", cmd_linux, "as uboot, plus the build's kernel/initramfs/dtb")):
        p = sub.add_parser(name, help=help_)
        p.add_argument("--images", default=DEFAULT_IMAGES, help=f"build output/images (default {DEFAULT_IMAGES})")
        p.add_argument("--uboot-addr", type=lambda v: int(v, 0), default=0x21000000)
        p.add_argument("--serial", default="/dev/ttyUSB0" if name == "uboot" else None,
                       help="serial console" + (" (optional: boot log, --root-password)" if name == "linux" else ""))
        p.set_defaults(fn=fn)
        if name == "linux":
            p.add_argument("--dtb", default="proxima-9311-air.dtb")
            p.add_argument("--nand-root", action="store_true",
                           help="no initramfs: mount the rootfs flashed to userapp1 (slot B), whatever slot is active")
            p.add_argument("--bootargs",
                           help="kernel command line (default: initramfs, or with --nand-root the flash boot's)")
            p.add_argument("--follow", type=float, default=90, help="seconds of boot log to show")
            p.add_argument("--root-password", help="claim the booted system with this root password")

    a = ap.parse_args()
    if getattr(a, "root_password", None) and not a.serial:
        ap.error("--root-password needs --serial")
    a.fn(a)


if __name__ == "__main__":
    main()
