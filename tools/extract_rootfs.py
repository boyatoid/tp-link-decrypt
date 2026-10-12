#!/usr/bin/env python3
"""Extract the root filesystem from a decrypted TP-Link image.

Why this exists: binwalk does not reliably find the UBI container in these images.
On the Archer AX21 V5.46 decrypted output it reports no signatures at all, even
though a UBI volume table starts at 0x1356 - the erase-block headers are simply not
at an offset binwalk scans. This carves UBI by magic, extracts its volumes, and then
unpacks whichever filesystem each volume holds.

Extraction is contained: these images are untrusted input, so a '..' component or
an absolute path in an entry must not write outside the output directory, and a
symlink planted by an earlier entry must not be followed by a later write.

It also works around a macOS/Windows problem: these root filesystems contain paths
differing only in case (for example EU/ and eu/), so extracting onto a
case-insensitive filesystem collides. Colliding entries get a __CASEDUP suffix
instead of overwriting each other or aborting half way.

Requires:  pip install ubi_reader PySquashfsImage

Usage:  extract_rootfs.py <decrypted.bin> -o outdir
"""
import argparse, os, re, shutil, struct, subprocess, sys, tempfile

def safe_dest(out, rel):
    """Absolute destination for rel under out, or None if it escapes.

    realpath() resolves any symlink already planted in the tree, so this also stops a
    later entry writing through an earlier symlink that points outside out.
    """
    root = os.path.realpath(out)
    dst = os.path.realpath(os.path.join(root, rel))
    if dst != root and not dst.startswith(root + os.sep):
        return None
    return dst


UBI_MAGIC = b'UBI#'
SQUASHFS_LE = b'hsqs'
UBIFS_MAGIC = b'\x31\x18\x10\x06'


def find_ubi(data):
    """(offset, confirmed) for the UBI volume table.

    confirmed is True when the magic repeats at a plausible erase-block stride. Without
    that, the hit may just be the string 'UBI#' inside a file, so the caller warns rather
    than presenting a guess as a finding.
    """
    hits = [m.start() for m in re.finditer(re.escape(UBI_MAGIC), data)]
    if not hits:
        return None, False
    hitset = set(hits)
    for h in hits:
        for peb in (0x20000, 0x40000, 0x10000, 0x1000):   # common erase-block sizes
            if h + peb in hitset:
                return h, True
    return hits[0], False


def extract_squashfs(img, out):
    try:
        from PySquashfsImage import SquashFsImage
    except ImportError:
        sys.exit("need PySquashfsImage: pip install PySquashfsImage")
    seen, files, links, dupes, unsafe, flat = set(), 0, 0, 0, 0, 0
    with SquashFsImage.from_file(img) as fs:
        for entry in fs:
            rel = entry.path.lstrip('/')
            if not rel:
                continue
            dst = safe_dest(out, rel)
            if dst is None:
                unsafe += 1
                print(f"    REFUSED (escapes output dir): {entry.path}")
                continue
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
                    # Host cannot make the link; record the target as text so the tree
                    # stays complete. Counted, because it is no longer a real symlink.
                    flat += 1
                    with open(dst, 'w') as f:
                        f.write(entry.readlink())
            elif entry.is_file:
                with open(dst, 'wb') as f:
                    f.write(entry.read_bytes())
                files += 1
    print(f"    squashfs: {files} files, {links} symlinks"
          + (f", {dupes} case collisions renamed __CASEDUP" if dupes else "")
          + (f", {flat} symlinks flattened to text files" if flat else "")
          + (f", {unsafe} entries REFUSED as unsafe paths" if unsafe else ""))


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
    off, confirmed = find_ubi(data)
    if off is None:
        sys.exit("no UBI container found (is this image decrypted?)")
    print(f"UBI container at {off:#x}" + ("" if confirmed else "  (UNCONFIRMED)"))
    if not confirmed:
        print("  warning: the magic does not repeat at a plausible erase-block stride,\n"
              "  so this may be the string 'UBI#' inside a file rather than a container.")

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
                shutil.copy(v, dest + '.bin')
                print("    unrecognised filesystem, copied raw")
    print(f"\nextracted to {a.out}")


if __name__ == '__main__':
    main()
