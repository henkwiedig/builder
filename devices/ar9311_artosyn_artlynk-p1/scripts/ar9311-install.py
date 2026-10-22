#!/usr/bin/env python3
"""
Back up, install and switch the NAND slots of a BetaFPV P1 / Artosyn PROXIMA
9311 that runs this build from RAM (ar9311-usbboot.py linux). Everything goes
through that system over SSH, none of it through the stock firmware.

  ar9311-install.py backup DIR
      every partition (data, bad blocks skipped) and the whole chip (with OOB)
      into DIR, md5 checked on both ends, plus MD5SUMS and manifest.json
  ar9311-install.py install openipc.ar9311-nand-artosyn.tgz --backup DIR [--activate] [--dry-run]
      the build's slot-B images to kernel1, dtb1 and userapp1, each verified
      (--dry-run: every check and the staging, nothing written)
  ar9311-install.py activate a|b
      the slot the stock SPL boots next (openipc-bsel, the GPT's bit 47)
  ar9311-install.py status

Slots: the SPL boots whichever of the env/uboot/kernel/dtb/userapp pairs the
GPT marks active and points the kernel at that slot's userapp. Stock stays in
slot A (the *0 partitions), which this script never writes; OpenIPC goes to
slot B. "activate a" is the way back to stock, from any RAM boot.

Safety: install refuses unless DIR is a backup of this very unit (its factory
partition -- RF calibration, unique per unit -- must match), unless the board
runs from RAM, and if kernel1 or dtb1 has a bad block (whether the SPL skips
one the way nandwrite does is unknown). Images are staged in the board's /tmp
and checked before anything is erased; raw partitions are read back, the
rootfs through UBI. Nothing is activated without --activate or "activate b".

SSH: one master connection (the root password is asked for once, or your key
is used), every command over it. A fresh RAM boot has no root password and
runs no commands until one is set: log in once (ssh root@HOST) to set it. The
RAM system makes new host keys every boot, so they are not checked.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

# mtd1..mtd20 (mtd0 is the whole 128 MiB chip), as the stock GPT and the
# ml-kernel DTS lay them out.
LAYOUT = [
    ("spl0", 0x40000), ("spl1", 0x40000), ("spl2", 0x40000), ("spl3", 0x40000),
    ("gpt0", 0x40000), ("gpt1", 0x40000), ("vendor", 0x80000), ("factory", 0x600000),
    ("env0", 0x60000), ("env1", 0x60000), ("uboot0", 0xc0000), ("uboot1", 0xc0000),
    ("kernel0", 0x600000), ("kernel1", 0x600000), ("dtb0", 0x60000), ("dtb1", 0x60000),
    ("userapp0", 0x2d00000), ("userapp1", 0x2d00000), ("usr_data", 0x600000), ("usr_log", 0x600000),
]
CHIP_SIZE = 0x8000000
SLOT_B = ("kernel1", "dtb1", "userapp1")
PKG_FILES = ("uImage.ar9311", "proxima-9311-air.dtb", "rootfs.ubi.ar9311")
STAGE = "/tmp/ar9311-install"
UBI_DEV = 7

# ---------------------------------------------------------------- SSH


class Board:
    def __init__(self, host):
        self.host = host
        self.tmp = tempfile.mkdtemp(prefix="ar9311-install-")
        self.sock = os.path.join(self.tmp, "ssh")
        self.opts = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "LogLevel=ERROR", "-o", "ServerAliveInterval=10", "-S", self.sock]

    def __enter__(self):
        if subprocess.run(["ssh", *self.opts, "-o", "ConnectTimeout=10", "-M", "-fN",
                           f"root@{self.host}"]).returncode:
            shutil.rmtree(self.tmp)
            sys.exit(f"cannot log in to root@{self.host} (RAM-booted with ar9311-usbboot.py linux?)")
        r = self.run("echo ok", check=False)
        if r.returncode or r.stdout.strip() != b"ok":
            self.close()
            if b"not been set up" in r.stderr:
                sys.exit(f"the board has no root password yet: log in once (ssh root@{self.host}), "
                         "set one, then run this again")
            sys.exit(f"root@{self.host}: {r.stderr.decode(errors='replace').strip()}")
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        subprocess.run(["ssh", *self.opts, "-O", "exit", f"root@{self.host}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run(self, cmd, check=True, stdin=None, stdout=subprocess.PIPE):
        r = subprocess.run(["ssh", *self.opts, f"root@{self.host}", cmd],
                           stdin=stdin, stdout=stdout, stderr=subprocess.PIPE)
        if check and r.returncode:
            sys.exit(f"board: `{cmd}` failed: {r.stderr.decode(errors='replace').strip()}")
        return r

    def text(self, cmd):
        return self.run(cmd).stdout.decode(errors="replace")

    def mtd(self):
        """{name: (num, size)} after checking /proc/mtd is the P1 layout."""
        parts = {}
        for line in self.text("cat /proc/mtd").splitlines()[1:]:
            m = re.match(r'mtd(\d+): ([0-9a-f]+) [0-9a-f]+ "([^"]+)"', line)
            if m:
                parts[int(m.group(1))] = (m.group(3), int(m.group(2), 16))
        want = {i + 1: p for i, p in enumerate(LAYOUT)}
        if parts.get(0, (None, 0))[1] != CHIP_SIZE or {k: v for k, v in parts.items() if k} != want:
            sys.exit("board: /proc/mtd is not the P1 layout:\n" +
                     "\n".join(f"  mtd{k}: {n} {s:#x}" for k, (n, s) in sorted(parts.items())))
        return {name: (num, size) for num, (name, size) in parts.items() if num}

    def ram_boot(self):
        cmdline = self.text("cat /proc/cmdline")
        return "root=/dev/ram0" in cmdline or "rdinit=" in cmdline and "root=" not in cmdline

    def active_slot(self):
        """0 or 1 from gpt0, None if the GPT is unreadable or mixed."""
        r = self.run("openipc-bsel check_flash", check=False)
        m = re.search(rb"bank=([01])", r.stdout)
        return int(m.group(1)) if m else None

    def md5(self, cmd, pipefail=True):
        """md5 of cmd's output. pipefail off where cmd ends in head -c, which
        closes the pipe on a writer that may still be writing."""
        out = self.text(f"{'set -o pipefail; ' if pipefail else ''}{cmd} | md5sum")
        return out.split()[0]

    def bad_blocks(self, num):
        return int(self.text(f"cat /sys/class/mtd/mtd{num}/bad_blocks"))


def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


SLOT_NAME = {0: "A (stock)", 1: "B"}

# ---------------------------------------------------------------- backup


def dump(board, dev, path, oob):
    """nanddump dev into path; md5 taken on the board in the same pass."""
    fifo = "/tmp/ar9311-dump"
    cmd = (f"set -o pipefail; rm -f {fifo}; mkfifo {fifo}; md5sum < {fifo} > {fifo}.md5 & "
           f"nanddump --bb=skipbad {'--oob' if oob else '--omitoob'} -q {dev} | tee {fifo} || exit 1; "
           f"wait; cat {fifo}.md5 >&2; rm -f {fifo} {fifo}.md5")
    with open(path, "wb") as f:
        r = board.run(cmd, check=False, stdout=f)
    m = re.search(rb"\b([0-9a-f]{32})\b", r.stderr)
    if r.returncode or not m:
        sys.exit(f"dump of {dev} failed: {r.stderr.decode(errors='replace').strip()}")
    local = md5_file(path)
    if local != m.group(1).decode():
        sys.exit(f"{path}: md5 {local} here, {m.group(1).decode()} on the board")
    return local


def cmd_backup(a):
    if os.path.exists(a.dir) and os.listdir(a.dir):
        sys.exit(f"{a.dir} exists and is not empty")
    os.makedirs(a.dir, exist_ok=True)
    with Board(a.host) as board:
        parts = board.mtd()
        manifest = {
            "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "proc_mtd": board.text("cat /proc/mtd"),
            "cmdline": board.text("cat /proc/cmdline").strip(),
            "active_slot": board.active_slot(),
            "format": "<partition>.bin: nanddump --bb=skipbad --omitoob (data, bad blocks "
                      "skipped); mtd0-full-oob.bin: the whole chip with OOB, bad blocks skipped",
            "partitions": {},
        }
        sums = []
        for name, (num, size) in sorted(parts.items(), key=lambda p: p[1][0]):
            bad = board.bad_blocks(num)
            md5 = dump(board, f"/dev/mtd{num}", os.path.join(a.dir, f"{name}.bin"), oob=False)
            got = os.path.getsize(os.path.join(a.dir, f"{name}.bin"))
            manifest["partitions"][name] = {"mtd": num, "size": size, "bad_blocks": bad,
                                            "bytes": got, "md5": md5}
            sums.append(f"{md5}  {name}.bin")
            print(f"  {name:9s} {got // 1024:6d} KiB  bad blocks {bad}  {md5}")
        md5 = dump(board, "/dev/mtd0", os.path.join(a.dir, "mtd0-full-oob.bin"), oob=True)
        manifest["mtd0-full-oob.bin"] = {"bad_blocks": board.bad_blocks(0), "md5": md5,
                                         "bytes": os.path.getsize(os.path.join(a.dir, "mtd0-full-oob.bin"))}
        sums.append(f"{md5}  mtd0-full-oob.bin")
        print(f"  mtd0 (whole chip, with OOB)      {md5}")
    with open(os.path.join(a.dir, "MD5SUMS"), "w") as f:
        f.write("\n".join(sums) + "\n")
    with open(os.path.join(a.dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"backup complete: {a.dir} (active slot {SLOT_NAME.get(manifest['active_slot'], '?')})")

# ---------------------------------------------------------------- install


def ubi_volume_md5(path, vol_id=0):
    """(md5, length) of a UBI image's volume as the kernel reads it back."""
    data = open(path, "rb").read()
    if data[:4] != b"UBI#":
        sys.exit(f"{path}: not a UBI image")
    peb = 0x20000
    vid_off, data_off = struct.unpack_from(">II", data, 16)
    lebs = {}
    for i in range(0, len(data), peb):
        vid = data[i + vid_off:i + vid_off + 64]
        if vid[:4] == b"UBI!" and struct.unpack_from(">I", vid, 8)[0] == vol_id:
            lebs[struct.unpack_from(">I", vid, 12)[0]] = data[i + data_off:i + peb]
    if not lebs or sorted(lebs) != list(range(len(lebs))):
        sys.exit(f"{path}: volume {vol_id} is not a run of LEBs from 0")
    blob = b"".join(lebs[n] for n in range(len(lebs)))
    return hashlib.md5(blob).hexdigest(), len(blob)


def check_package(path, workdir):
    with tarfile.open(path) as tar:
        for member in tar.getmembers():
            name = member.name
            if not member.isfile() or "/" in name or name not in PKG_FILES + tuple(f + ".md5sum" for f in PKG_FILES):
                sys.exit(f"{path}: unexpected member {name!r}")
            with tar.extractfile(member) as src, open(os.path.join(workdir, name), "wb") as dst:
                shutil.copyfileobj(src, dst)
    for name in PKG_FILES:
        f = os.path.join(workdir, name)
        if not os.path.exists(f) or not os.path.exists(f + ".md5sum"):
            sys.exit(f"{path}: {name} or its .md5sum is missing")
        if open(f + ".md5sum").read().split()[0] != md5_file(f):
            sys.exit(f"{path}: {name} does not match its .md5sum")
    kernel = open(os.path.join(workdir, PKG_FILES[0]), "rb").read()
    n, s = struct.unpack_from("<I", kernel, 0x10)[0], struct.unpack_from("<I", kernel, 0x20)[0]
    if kernel[:4] != b"OTRA" or n + 0x40 != len(kernel) or sum(kernel[0x40:]) & 0xFFFFFFFF != s:
        sys.exit(f"{PKG_FILES[0]}: not an OTRA kernel container with a valid sum")
    dtb = open(os.path.join(workdir, PKG_FILES[1]), "rb").read()
    if dtb[:4] != b"\xd0\x0d\xfe\xed" or b"ubi.mtd=18" not in dtb:
        sys.exit(f"{PKG_FILES[1]}: not a dtb with the flash boot command line (ubi.mtd=18)")


def cmd_install(a):
    work = tempfile.mkdtemp(prefix="ar9311-pkg-")
    try:
        check_package(a.package, work)
        files = {name: os.path.join(work, name) for name in PKG_FILES}
        rootfs_md5, rootfs_len = ubi_volume_md5(files["rootfs.ubi.ar9311"])
        try:
            backup = dict(reversed(line.split()) for line in open(os.path.join(a.backup, "MD5SUMS")))
        except OSError as e:
            sys.exit(f"--backup {a.backup}: {e}")

        with Board(a.host) as board:
            parts = board.mtd()
            if not board.ram_boot():
                sys.exit("the board does not run from RAM: install only from ar9311-usbboot.py linux")
            factory = board.md5(f"nanddump --bb=skipbad --omitoob -q /dev/mtd{parts['factory'][0]}")
            if backup.get("factory.bin") != factory:
                sys.exit(f"{a.backup} is not a backup of this unit (factory differs): "
                         "run backup first")
            slot = board.active_slot()
            if slot is None:
                sys.exit("gpt0: no clear active slot (openipc-bsel check_flash)")
            if slot == 1:
                print("note: slot B is active -- until this install is done, power it up from "
                      "RAM only; 'activate a' brings stock back")
            for name in ("kernel1", "dtb1"):
                if board.bad_blocks(parts[name][0]):
                    sys.exit(f"{name} has a bad block: not written (the SPL may not skip it)")
            sizes = {"kernel1": PKG_FILES[0], "dtb1": PKG_FILES[1]}
            for part, name in sizes.items():
                if os.path.getsize(files[name]) > parts[part][1]:
                    sys.exit(f"{name} does not fit {part}")
            attached = board.text("cat /sys/class/ubi/ubi*/mtd_num 2>/dev/null || true").split()
            if str(parts["userapp1"][0]) in attached:
                sys.exit("userapp1 is attached to UBI: install only from a RAM boot that does not use it")

            print("staging the images on the board ...")
            board.run(f"rm -rf {STAGE}; mkdir -p {STAGE}")
            for name, f in files.items():
                with open(f, "rb") as src:
                    board.run(f"cat > {STAGE}/{name}", stdin=src)
                if board.md5(f"cat {STAGE}/{name}") != md5_file(f):
                    sys.exit(f"{name}: staged copy differs")
            if a.dry_run:
                board.run(f"rm -rf {STAGE}")
                print("dry run: every check passed and the images staged intact; nothing written")
                return

            for part, name in sizes.items():
                num = parts[part][0]
                assert part in SLOT_B
                length = os.path.getsize(files[name])
                print(f"writing {part} (mtd{num}) ...")
                board.run(f"flash_erase -q /dev/mtd{num} 0 0 && nandwrite -p -q /dev/mtd{num} {STAGE}/{name}")
                back = board.md5(f"nanddump --bb=skipbad --omitoob -q -l {length} /dev/mtd{num} | head -c {length}",
                                 pipefail=False)
                if back != md5_file(files[name]):
                    sys.exit(f"{part}: readback differs -- slot B is incomplete, do not activate it")
                print(f"  {part}: {length} bytes, readback ok")

            num = parts["userapp1"][0]
            assert "userapp1" in SLOT_B
            print(f"writing userapp1 (mtd{num}) with ubiformat ...")
            board.run(f"ubiformat /dev/mtd{num} -y -q -f {STAGE}/rootfs.ubi.ar9311")
            board.run(f"ubiattach -m {num} -d {UBI_DEV} >/dev/null")
            try:
                board.run(f"i=0; while [ ! -e /dev/ubi{UBI_DEV}_0 ] && [ $i -lt 50 ]; do "
                          f"usleep 100000; i=$((i+1)); done")
                vols = board.text(f"cat /sys/class/ubi/ubi{UBI_DEV}_*/name").split()
                back = board.md5(f"head -c {rootfs_len} /dev/ubi{UBI_DEV}_0")
            finally:
                board.run(f"ubidetach -d {UBI_DEV}", check=False)
            if sorted(vols) != ["rootfs", "rootfs_data"] or back != rootfs_md5:
                sys.exit(f"userapp1: volumes {vols}, rootfs md5 {back} (want {rootfs_md5}) -- "
                         "slot B is incomplete, do not activate it")
            print(f"  userapp1: volumes rootfs + rootfs_data, rootfs readback ok")
            board.run(f"rm -rf {STAGE}")

            if a.activate:
                activate(board, parts, 1)
            else:
                print("slot B is written, slot A is still active. Next:\n"
                      "  ar9311-usbboot.py linux --nand-root   (optional: boot slot B's rootfs from RAM)\n"
                      "  ar9311-install.py activate b          then power-cycle without the CLK short")
    finally:
        shutil.rmtree(work, ignore_errors=True)

# ---------------------------------------------------------------- activate / status


def dtb_model(blob):
    """The root node's model property of a flattened device tree, or None."""
    if blob[:4] != b"\xd0\x0d\xfe\xed":
        return None
    off_struct, off_strings = struct.unpack_from(">II", blob, 8)
    pos, depth = off_struct, 0
    while pos + 4 <= len(blob):
        token = struct.unpack_from(">I", blob, pos)[0]
        pos += 4
        if token == 1:          # BEGIN_NODE
            end = blob.index(b"\0", pos)
            pos = (end + 4) & ~3
            depth += 1
        elif token == 2:        # END_NODE
            depth -= 1
        elif token == 3:        # PROP
            length, nameoff = struct.unpack_from(">II", blob, pos)
            name = blob[off_strings + nameoff:blob.index(b"\0", off_strings + nameoff)]
            value = blob[pos + 8:pos + 8 + length]
            if depth == 1 and name == b"model":
                return value.rstrip(b"\0").decode(errors="replace")
            pos = (pos + 8 + length + 3) & ~3
        elif token == 4:        # NOP
            continue
        else:
            return None
    return None


def slot_content(board, parts, n):
    """(kernel is OTRA, dtb model, userapp is UBI, dtb has our flash command line)."""
    head = board.run(f"nanddump --bb=skipbad --omitoob -q -l 2048 /dev/mtd{parts[f'kernel{n}'][0]} | head -c 4").stdout
    dtb = board.run(f"nanddump --bb=skipbad --omitoob -q -l 32768 /dev/mtd{parts[f'dtb{n}'][0]}").stdout
    ubi = board.run(f"nanddump --bb=skipbad --omitoob -q -l 2048 /dev/mtd{parts[f'userapp{n}'][0]} | head -c 4").stdout
    return head == b"OTRA", dtb_model(dtb), ubi == b"UBI#", b"root=ubi0:rootfs" in dtb


def activate(board, parts, slot, force=False):
    # Slot B starts out holding an older stock firmware, which looks complete
    # too: only an install from this build counts, unless forced.
    if slot == 1 and not force:
        kernel, model, ubi, ours = slot_content(board, parts, 1)
        if not (kernel and model and ubi and ours):
            sys.exit(f"slot B holds no OpenIPC install (kernel {kernel}, dtb {model!r}, UBI {ubi}, "
                     f"flash command line {ours}): not activated (--force activates it anyway)")
    print(board.text(f"openipc-bsel set {slot}").strip())
    if board.active_slot() != slot:
        sys.exit("gpt0 does not read back the new slot -- check it before power-cycling")
    print(f"slot {SLOT_NAME[slot]} is active from the next power-up")


def cmd_activate(a):
    with Board(a.host) as board:
        activate(board, board.mtd(), {"a": 0, "b": 1}[a.slot], a.force)


def cmd_status(a):
    with Board(a.host) as board:
        parts = board.mtd()
        cmdline = board.text("cat /proc/cmdline")
        m = re.search(r"ubi\.mtd=(\d+)", cmdline)
        running = "RAM" if board.ram_boot() else {"17": "slot A", "18": "slot B"}.get(m and m.group(1), "?")
        print(f"running from: {running}")
        print(f"active slot:  {SLOT_NAME.get(board.active_slot(), 'unclear (openipc-bsel check_flash)')}")
        for n in (0, 1):
            kernel, model, ubi, ours = slot_content(board, parts, n)
            print(f"slot {'AB'[n]}: {'OpenIPC' if ours else 'stock or other'}: kernel{n} "
                  f"{'OTRA' if kernel else '-'}, dtb{n} {model!r}, userapp{n} {'UBI' if ubi else '-'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="192.168.3.104", help="the RAM-booted board (default %(default)s)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("backup", help="dump every partition and the whole chip")
    p.add_argument("dir")
    p.set_defaults(fn=cmd_backup)
    p = sub.add_parser("install", help="write the slot-B images")
    p.add_argument("package", help="openipc.ar9311-nand-artosyn.tgz")
    p.add_argument("--backup", required=True, help="this unit's backup directory")
    p.add_argument("--activate", action="store_true", help="make slot B active once written")
    p.add_argument("--dry-run", action="store_true", help="all checks and the staging, no writes")
    p.set_defaults(fn=cmd_install)
    p = sub.add_parser("activate", help="the slot the SPL boots next")
    p.add_argument("slot", choices=("a", "b"))
    p.add_argument("--force", action="store_true", help="activate slot B whatever it holds")
    p.set_defaults(fn=cmd_activate)
    p = sub.add_parser("status", help="running and active slot, what each slot holds")
    p.set_defaults(fn=cmd_status)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
