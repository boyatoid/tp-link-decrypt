#!/usr/bin/env python3
"""Extract the root filesystem from a decrypted TP-Link image.

Why this exists: binwalk does not reliably find the UBI container in these images.
On the Archer AX21 V5.46 decrypted output it reports no signatures at all, even
though a UBI volume table starts at 0x1356 - the erase-block headers are simply not
at an offset binwalk scans. This carves UBI by magic, extracts its volumes, and then
unpacks whichever filesystem each volume holds.

It also works around a macOS/Windows problem: these root filesystems contain paths
differing only in case (for example EU/ and eu/), so extracting onto a
case-insensitive filesystem collides. Colliding entries get a __CASEDUP suffix
instead of overwriting each other or aborting half way.

Requires:  pip install ubi_reader PySquashfsImage

Usage:  extract_rootfs.py <decrypted.bin> -o outdir
"""
import argparse, os, re, shutil, struct, subprocess, sys, tempfile

UBI_MAGIC = b'UBI#'
SQUASHFS_LE = b'hsqs'
UBIFS_MAGIC = b'\x31\x18\x10\x06'


def find_ubi(data):
    """Offset of the UBI volume table: first UBI# that repeats at a sane erase-block stride."""
    hits = [m.start() for m in re.finditer(re.escape(UBI_MAGIC), data)]
    if not hits:
        return None
    for h in hits:
        for peb in (0x20000, 0x40000, 0x10000, 0x1000):   # common erase-block sizes
            if h + peb in hits:
                return h
    return hits[0]


def extract_squashfs(img, out):
    try:
        from PySquashfsImage import SquashFsImage
    except ImportError:
        sys.exit("need PySquashfsImage: pip install PySquashfsImage")
    seen, files, links, dupes = set(), 0, 0, 0
    with SquashFsImage.from_file(img) as fs:
        for entry in fs:
            rel = entry.path.lstrip('/')
            if not rel:
                continue
            dst = os.path.join(out, rel)
            key = dst.lower()
            if key in seen:            # case-insensitive host filesystem
                dst += '__CASEDUP'
                dupes += 1
            seen.add(key)
            if entry.is_dir:
                os.makedirs(dst, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if entry.is_symlink:
                links += 1
                try:
                    os.symlink(entry.readlink(), dst)
                except (FileExistsError, OSError):
                    with open(dst, 'w') as f:
                        f.write(entry.readlink())
            elif entry.is_file:
                with open(dst, 'wb') as f:
                    f.write(entry.read_bytes())
                files += 1
    print(f"    squashfs: {files} files, {links} symlinks"
          + (f", {dupes} case collisions renamed __CASEDUP" if dupes else ""))


def extract_ubifs(img, out):
    exe = shutil.which('ubireader_extract_files')
    if not exe:
        sys.exit("need ubi_reader: pip install ubi_reader")
    os.makedirs(out, exist_ok=True)
    r = subprocess.run([exe, '-k', '-o', out, img], capture_output=True)
    if r.returncode and not os.listdir(out):
        sys.exit(f"ubireader_extract_files failed: {r.stderr.decode(errors='replace')[-400:]}")
    n = sum(len(f) for _, _, f in os.walk(out))
    print(f"    ubifs: {n} files"
          + ("  (some entries skipped: permission denied)" if r.returncode else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image')
    ap.add_argument('-o', '--out', required=True)
    a = ap.parse_args()

    data = open(a.image, 'rb').read()
    off = find_ubi(data)
    if off is None:
        sys.exit("no UBI container found (is this image decrypted?)")
    print(f"UBI container at {off:#x}")

    os.makedirs(a.out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        carved = os.path.join(tmp, 'carved.ubi')
        with open(carved, 'wb') as f:
            f.write(data[off:])
        exe = shutil.which('ubireader_extract_images')
        if not exe:
            sys.exit("need ubi_reader: pip install ubi_reader")
        vol_dir = os.path.join(tmp, 'vols')
        r = subprocess.run([exe, '-o', vol_dir, carved], capture_output=True)
        vols = [os.path.join(dp, f) for dp, _, fs in os.walk(vol_dir) for f in fs]
        if not vols:
            sys.exit(f"no volumes extracted: {r.stderr.decode(errors='replace')[-400:]}")
        for v in sorted(vols):
            name = os.path.basename(v)
            magic = open(v, 'rb').read(4)
            label = re.sub(r'^img-\d+_vol-', '', name).replace('.ubifs', '')
            dest = os.path.join(a.out, label)
            print(f"  volume {label} ({os.path.getsize(v)} bytes, magic {magic.hex()})")
            if magic == SQUASHFS_LE:
                extract_squashfs(v, dest)
            elif magic == UBIFS_MAGIC:
                extract_ubifs(v, dest)
            else:
                os.makedirs(a.out, exist_ok=True)
                shutil.copy(v, dest + '.bin')
                print("    unrecognised filesystem, copied raw")
    print(f"\nextracted to {a.out}")


if __name__ == '__main__':
    main()
