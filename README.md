# This fork

Maintained by @boyatoid, forked from
[robbins/tp-link-decrypt](https://github.com/robbins/tp-link-decrypt).

Everything in this repository is the work of robbins and the authors credited under
"Credit" below, **except** the following, which are mine:

- Portable build and key extraction, tested on macOS / Apple Silicon: `CC` honoured,
  libcrypto located via `pkg-config` then Homebrew's keg-only `openssl@3`, and
  curl/wget, shasum/sha256sum and nm/llvm-nm/gnm/eu-nm fallbacks.
- `--keys rsa1,rsa0,des`, to extract only the key an image format needs rather than
  taking three multi-megabyte downloads. Skipped keys become marked stubs so `make`
  still links.
- Per-key hash pinning, so extracting a single key can be verified at all - upstream
  pinned only the combined `RSA_0`+`RSA_1`.
- `tools/extract_rootfs.py` - carves the UBI container by magic, unpacks squashfs or
  UBIFS per volume, and handles paths that collide on case-insensitive filesystems.
- `docs/cloud-router-images.md` - a worked example on an Archer AX21 V5.46, with
  hashes to reproduce it.

Everything from "Info" onward is upstream's text and speaks in robbins' voice: "I" and
"me" there refer to robbins, not to me.

# Info
This is a fork of @watchfulip's tp-link-decrypt repo that I have (with permission) taken over maintenance of and have added support for TPLink/Omada network switch firmware.
I extracted the unencrypted firmware from an Omada switch SPI flash chip and discovered the keys. It turns out the same binaries are included in public TP-Link GPL releases and can be easily downloaded.
The below README has been edited from watchfulip/tp-link-decrypt and the original can be seen there.

# Credit
- @robbins Direct upstream of this fork: https://github.com/robbins/tp-link-decrypt
- @watchfulip watchfulip@protonmail.com Original extensive TPLink firmware research and code that started this project: https://watchfulip.github.io/28-12-24/tp-link_c210_v2.html
- @GxdTxnz 3 Jan 2025 Preinstall script and enhanced extract_keys script
- @tangrs 22 Sep 2025 Finding that the relevant binaries are published in TPLink GPL code dumps and how to extract keys from them: https://blog.tangrs.id.au/2025/09/22/decrypting-tplink-smart-switch-firmware/

# Instructions
1.  (optional)  Run `./preinstall.sh` or `nix develop` to satisfy dependencies

    `preinstall.sh` is apt-only. On macOS:

        brew install binwalk openssl@3 pkg-config
        pip install ubi_reader PySquashfsImage

    The build also needs libcrypto; the Makefile finds it via `pkg-config`, then
    Homebrew's keg-only `openssl@3`, then a bare `-lcrypto`.

2.  Run ./extract_keys.sh  to extract RSA/DES keys from TP-Link Firmware we download from vendor

    Each key comes from its own multi-megabyte vendor download, so you can ask for
    only the ones your image format needs:

        ./extract_keys.sh --keys rsa1        # router images with "fw-type:" in the header
        ./extract_keys.sh --keys rsa0        # Tapo cameras
        ./extract_keys.sh --keys des         # Omada / TPLink switches

    Keys you skip become clearly-marked stub headers so `make` still links; the
    resulting binary then handles only the formats whose keys you extracted.
    Runs non-interactively; pass --verbose to see binwalk's output.

    If binwalk yields no candidate binary (it needs `ubi_reader` on `PATH`, and
    without it extracts nothing while still exiting cleanly), the script says so and
    retries via `tools/extract_rootfs.py` rather than reporting a missing key.

3.  Run `make` or `nix build`

    `make` needs nothing further. For `nix build`, the flake only sees git-tracked
    files, so the generated headers have to be staged first - and since they are
    gitignored (they hold key material extracted from TP-Link binaries) that needs
    `-f`:

        git add -f include
        nix build
        git restore --staged include

    **Do not commit those headers.** Unstage them as above once the build is done.
    TODO #5 is to add them to the Nix store directly and drop this step.

4.  Get the image and decrypt it

    Vendor downloads arrive as a zip, so unpack it first:

        unzip 'Archer AX21_V5.6_250814.zip'
        ./bin/tp-link-decrypt 'Archer AX21_V5.6_250814.bin'

    Expected output:

        fw-type: found
        RSA-2048
        Firmware verification successful

    "Firmware verification successful" is an RSA-2048 PSS signature check over the
    image, so a wrong or truncated key fails loudly instead of producing plausible
    garbage. The plaintext is written alongside the input as `<fw file>.dec`.

5.  To unpack the decrypted image, `tools/extract_rootfs.py` carves the UBI container
    by magic and unpacks its volumes (`pip install ubi_reader PySquashfsImage`):

        python3 tools/extract_rootfs.py <fw file>.dec -o rootfs

    binwalk does not reliably locate UBI in these images - on the Archer AX21 V5.46
    decrypted output it reports no signatures at all, though a volume table starts at
    0x1356. The script also renames paths that collide on case-insensitive
    filesystems (macOS, Windows) instead of aborting half way.

See **docs/cloud-router-images.md** for a full worked example on an Archer AX21 V5.46,
including the macOS fixes and hashes to reproduce the result.

If you found this tool useful, feel free to let me or WatchfulIP watchfulip@protonmail.com know :)

NOTE:

This program uses libsecurity GPL code downloaded from https://static.tp-link.com/upload/gpl-code/2022/202211/20221130/c310v2_GPL.tar.bz2

TP-Link firmware links used:

- http://download.tplinkcloud.com/firmware/ax6000v2-up-ver1-1-2-P1[20230731-rel41066]_1024_nosign_2023-07-31_11.26.17_1693471186048.bin.rollback
- http://download.tplinkcloud.com/firmware/Tapo_C210v1_en_1.3.1_Build_221218_Rel.73283n_u_1679534600836.bin
- https://static.tp-link.com/resources/gpl/rtk-maple_gpl.tar.gz

# Contributing
LLM authored/co-authored commits are fine, provided you've tested the code yourself, but please don't use an LLM to write the PR description. Thanks.

-------------------------------------------------------------------------------

Great care has been taken not to infringe TP-Link's rights.

RSA & DES keys used for verification and decryption are taken from the firmware and other binary files TP-Link themselves publish.

This tool does not allow signed firmware to be created.  Thus, there is no danger of unauthorized hostile firmware being placed on devices facilitated by this software.

It is hoped this tool may be useful in itself permitting security researches to assist TP-Link with any vulnerabilties.

-------------------------------------------------------------------------------
