# Decrypting `fw-type:Cloud` router images (and doing it on macOS)

Worked example: **Archer AX21(US) V5.46, firmware 1.1.2 Build 20250814**, on macOS
(Apple Silicon). The same path should apply to other router images whose header carries
`fw-type:` at offset 0x14 — `tp-link-decrypt` already classifies these as "case 1".

Nothing here needs the device. You download the same image the router runs.

## 1. Get the image

TP-Link's per-model download page lists the firmware zip. Check the **hardware version on
the sticker underneath the router** — the web UI's version string can name a different
model family than the API reports (this unit reports `Archer AX21` while the bundled web
UI calls itself `AX23v2`), and the wrong hardware revision gets you the wrong image.

```sh
unzip 'Archer AX21_V5.6_250814.zip'
```

Recognising an encrypted one: `binwalk` finds **no signatures at all**, entropy sits at
~8.0 bits/byte end to end, and the first 0x130 bytes hold a hash, the literal string
`fw-type:Cloud`, and a signature block bracketed by `aa55`/`55aa`.

## 2. Extract only the key you need

These images need just `RSA_1`, which lives in the AX6000 v2's `usr/bin/nvrammanager`.
The Tapo RSA key and the switch DES keys are for other formats, so skip their downloads:

```sh
./extract_keys.sh --keys rsa1      # ~47 MB instead of three separate downloads
make
./bin/tp-link-decrypt <image>.bin
```

Skipped keys are written as clearly-marked stub headers so `make` still links. A binary
built that way handles `fw-type:` images only — point it at a Tapo or switch image and it
will fail, by design.

Expected output:

```
fw-type: found
RSA-2048
Firmware verification successful
```

**"Firmware verification successful" is meaningful** — it is an RSA-2048 PSS signature
check over the image, so a wrong or truncated key fails loudly rather than producing
plausible garbage.

## 3. Extract the root filesystem

binwalk does not find the UBI container in the decrypted output — on this image it reports
nothing, even though the volume table starts at **0x1356**. Use the bundled extractor,
which carves UBI by magic and then unpacks whichever filesystem each volume holds:

```sh
pip install ubi_reader PySquashfsImage
python3 tools/extract_rootfs.py <image>.bin.dec -o rootfs
```

```
UBI container at 0x1356
  volume kernel      (3373612 bytes)  - raw, Linux 4.4.60
  volume ubi_rootfs  (22855660 bytes) - squashfs: 2687 files, 464 symlinks
```

### macOS and other case-insensitive filesystems

These root filesystems contain paths differing only in case (`EU/` and `eu/`), so a plain
extract onto APFS/HFS+ or NTFS collides and standard tools abort part-way with
`error: file already exists` — leaving a half-populated tree that looks complete.
`extract_rootfs.py` renames collisions with a `__CASEDUP` suffix and reports the count, so
you can tell it happened.

## 4. What's inside

The web backend is **compiled Lua 5.1 bytecode**, not source, and it is non-standard
twice over (OpenWrt LNUM patch plus renumbered opcodes), so stock decompilers reject it.
See **[tp-link-lua-decompile](https://github.com/boyatoid/tp-link-lua-decompile)** to
recover the opcode table and decompile `usr/lib/lua`.

## macOS notes, collected

| problem | fix |
|---|---|
| `extract_keys.sh` wanted `wget`, `sha256sum` | now falls back to `curl` and `shasum` |
| its `nm` cannot read ELF objects | now tries `llvm-nm`, `gnm`, `eu-nm` in turn |
| `make` hardcoded `gcc` and a bare `-lcrypto` | Makefile now honours `CC`, and finds OpenSSL via `pkg-config` or Homebrew's keg-only `openssl@3` |
| binwalk silently extracted nothing | `ubi_reader` must be on `PATH`; `extract_keys.sh` now warns and retries via `tools/extract_rootfs.py` |
| `preinstall.sh` is apt-only | on macOS: `brew install binwalk openssl@3 pkg-config`, then `pip install ubi_reader PySquashfsImage` |

## Reproducing this exact result

| artifact | sha256 |
|---|---|
| `Archer AX21_V5.6_250814.zip` | `298622ae18be01ea84ecdc6fa303cd2e884303368e4b366b3003a6c5fa311b89` |
| `RSA_1` (extracted key) | `66a78aa710f52f7fcc92c69926f0b136a790189be5453f38d81bed90802e7a1c` |
| decrypted image | `150d30a8c4b30b4b3dfba60b0228ff95607ebe273b25e630c75039e91baf70e9` |

The decrypted output was confirmed byte-identical when rebuilt from freshly extracted keys
with the other three stubbed.
