#!/usr/bin/env python3
"""
BUILD_CMDS for artlynk-p1-vendor-firmware (see the sibling .mk).

Extracts the proprietary blobs ar9311_fpv_artlynk-p1 needs from BetaFPV's
stock P1 SKY OTA image (P1_SKY_*.img, Artosyn "ARTO" container) into
BINARIES_DIR/artlynk-p1/:

  ar8030.img            the stock P1 AR8030 baseband firmware (bb_demo_air.img),
                        for reference only: the target runs the Ascent air
                        firmware (package/ascent-vendor-firmware)
  bb_config_air.json    the stock P1 AR8030 RF config (air unit as DEV)
  p1_ascent_air.json    the P1 as AP with the Ascent link settings, built from
                        the ar8030 package's config (see make_ap_config())
  wave521c_k3_codec_fw.bin
                        Wave521C codec firmware (stock /usr/bin/chagall.bin.gz),
                        requested by the wave5 V4L2 driver as cnm/...
  nt99235-tuning-preview-fpv.bin
                        NT99235 ISP tuning (stock usr/usrdata/tunning/),
                        requested by the Artosyn ISP drivers as artosyn/...
  loader.bin, uboot0.img, vendor.img, p1.dtb
                        stock SPL, U-Boot, DDR training firmware and DT, for
                        booting a board over USB (devices/ar9311_fpv_artlynk-p1/
                        scripts/ar9311-usbboot.py)

Nothing is committed. The stock image is looked up locally first:
$ARTLYNK_P1_VENDOR_IMG, else <builder>/cache/vendor-images/P1_SKY_*.img
(newest match); if there is none, devices/ar9311_fpv_artlynk-p1/scripts/
fetch-vendor-img.sh downloads BetaFPV's Google Drive copy (file id from the
.mk, passed as argv[3]) to cache/vendor-images/P1_SKY_vendor.img.

Best-effort throughout, same contract as ascent-vendor-firmware: a missing
image or host tool prints a warning and leaves the artifact out; this script
never fails the build. Host prerequisites (not Buildroot packages):
python-lzo (pip install python-lzo), ubi_reader (pip install ubi_reader);
unsquashfs comes from $HOST_DIR (host-squashfs).
"""
import glob
import gzip
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FDT_MAGIC = b"\xd0\x0d\xfe\xed"

# stock rootfs path -> output name
ROOTFS_FILES = {
    "usr/usrdata/ar813x/bb_demo_air.img": "ar8030.img",
    "usr/usrdata/ar813x/bb_config_air.json": "bb_config_air.json",
    "usr/bin/chagall.bin.gz": "chagall.bin.gz",
    "usr/usrdata/tunning/nt99235_tuning_preview_fpv.bin": "nt99235-tuning-preview-fpv.bin",
}


def warn(msg):
    print(f"artlynk-p1-vendor-firmware: WARNING: {msg}", file=sys.stderr)


def find_image(binaries_dir, file_id=None):
    env = os.environ.get("ARTLYNK_P1_VENDOR_IMG")
    if env:
        return Path(env) if Path(env).is_file() else None
    # BINARIES_DIR = <builder>/openipc-<device>/output/images
    builder = Path(binaries_dir).resolve().parents[2]
    hits = sorted(glob.glob(str(builder / "cache/vendor-images/P1_SKY_*.img")), key=os.path.getmtime)
    if hits:
        return Path(hits[-1])
    fetch = builder / "devices/ar9311_fpv_artlynk-p1/scripts/fetch-vendor-img.sh"
    dest = builder / "cache/vendor-images/P1_SKY_vendor.img"
    if not fetch.is_file():
        return None
    env = dict(os.environ, **({"FILE_ID": file_id} if file_id else {}))
    if subprocess.run([str(fetch), str(dest)], env=env).returncode != 0:
        warn("could not fetch the stock P1 image")
        return None
    return dest if dest.is_file() else None


def extract_rootfs_files(userapp_img, out, tmp, host_dir):
    if not shutil.which("ubireader_extract_images"):
        warn("ubireader_extract_images not found (pip install ubi_reader) - no rootfs blobs")
        return
    unsquashfs = Path(host_dir, "bin/unsquashfs") if host_dir else None
    unsquashfs = str(unsquashfs) if unsquashfs and unsquashfs.exists() else shutil.which("unsquashfs")
    if not unsquashfs:
        warn("unsquashfs not found - no rootfs blobs")
        return
    ubi_out = tmp / "ubi"
    subprocess.run(["ubireader_extract_images", "-o", str(ubi_out), str(userapp_img)],
                   check=True, stdout=subprocess.DEVNULL)
    vols = [p for p in ubi_out.rglob("*") if p.is_file() and p.read_bytes()[:4] == b"hsqs"]
    if not vols:
        warn("no squashfs volume in the stock userapp UBI image")
        return
    root = tmp / "root"
    subprocess.run([unsquashfs, "-no-xattrs", "-d", str(root), str(vols[0]), *ROOTFS_FILES],
                   check=True, stdout=subprocess.DEVNULL)
    for src, name in ROOTFS_FILES.items():
        if (root / src).is_file():
            shutil.copy(root / src, out / name)
        else:
            warn(f"stock rootfs has no {src}")
    gz = out / "chagall.bin.gz"
    if gz.is_file():
        (out / "wave521c_k3_codec_fw.bin").write_bytes(gzip.decompress(gz.read_bytes()))
        gz.unlink()


def make_ap_config(out):
    """p1_ascent_air.json: the Ascent air config with the P1's own power setup.

    The P1 runs the Ascent air firmware (as AP, like an Ascent air unit), so
    the ar8030 package's (Ascent) air config is the base: link parameters,
    the full 42-entry channel table (a shorter table shifts the channel
    indices against the ground's) and 2TX_STBC broadcast. Only the P1's
    own PA setup comes from the stock P1 config: the power section and the
    PA calibration. Keep 2TX_STBC even though the P1 has one TX chain: the
    P1 only has RF port A fitted, and under the Ascent firmware 1TX goes
    out on port B. The stock "board" key is not carried over; the Ascent
    firmware has no board profiles.
    """
    import json

    ascent = HERE.parent / "ar8030/files/lib/firmware/ar8030/ar8030.json"
    stock = out / "bb_config_air.json"
    if not (ascent.is_file() and stock.is_file()):
        warn("no Ascent ar8030.json or stock bb_config_air.json - no p1_ascent_air.json")
        return
    p1, cfg = json.loads(stock.read_text()), json.loads(ascent.read_text())
    cfg["baseband"]["power_calibration"] = p1["baseband"]["power_calibration"]
    cfg["baseband"]["basic"]["power"] = p1["baseband"]["basic"]["power"]
    (out / "p1_ascent_air.json").write_text(json.dumps(cfg, indent=1))


def main():
    binaries_dir = sys.argv[1]
    host_dir = sys.argv[2] if len(sys.argv) > 2 else None
    file_id = sys.argv[3] if len(sys.argv) > 3 else None
    out = Path(binaries_dir, "artlynk-p1")
    out.mkdir(parents=True, exist_ok=True)

    img = find_image(binaries_dir, file_id)
    if img is None:
        warn("stock P1_SKY_*.img not found (set ARTLYNK_P1_VENDOR_IMG or put it in "
             "cache/vendor-images/) - building without AR8030/codec/ISP firmware")
        return 0
    print(f"artlynk-p1-vendor-firmware: using {img}")

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        parts = tmp / "parts"
        r = subprocess.run([sys.executable, str(HERE / "p1_ota_extract.py"), str(img), str(parts)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode != 0 or not parts.is_dir():
            warn(f"OTA extraction failed (python-lzo installed?): {r.stderr.strip()[-300:]}")
            return 0

        for name in ("loader.bin", "uboot0.img", "vendor.img"):
            if (parts / name).is_file():
                shutil.copy(parts / name, out / name)
        if (parts / "dtb0.img").is_file():
            d = (parts / "dtb0.img").read_bytes()
            i = d.find(FDT_MAGIC)
            if i >= 0:
                (out / "p1.dtb").write_bytes(d[i:i + struct.unpack_from(">I", d, i + 4)[0]])
        if (parts / "userapp0.img").is_file():
            try:
                extract_rootfs_files(parts / "userapp0.img", out, tmp, host_dir)
            except subprocess.CalledProcessError as e:
                warn(f"stock rootfs extraction failed: {e}")

    make_ap_config(out)
    for f in sorted(out.iterdir()):
        print(f"  {f.name}: {f.stat().st_size} B")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never fail the build
        warn(f"unexpected error: {e}")
        sys.exit(0)
