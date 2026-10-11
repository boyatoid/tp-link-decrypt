#!/usr/bin/env bash

# Watchful_IP - Find RSA KEYs in TP-Link firmware and write them to include dir
# VERSION=0.0.4
# VDATE=11-10-26
#
# 0.0.4: --keys selection (skip downloads you do not need), per-key verification,
#        non-interactive by default, and portability shims so this runs on macOS
#        and other non-GNU userlands. See docs/cloud-router-images.md.

set -e

# ---- which keys to extract -------------------------------------------------
# rsa1 : signed+encrypted router images whose header carries "fw-type:" (case 1)
# rsa0 : Tapo camera images (case 2)
# des  : Omada/TPLink switch images (case 0)
KEYS="rsa1,rsa0,des"
VERBOSE=0

usage() {
  cat >&2 <<USAGE
usage: $0 [--keys rsa1,rsa0,des] [--verbose]

  --keys    comma list of keys to extract (default: all three).
            Each key needs its own multi-megabyte download, so if you only care
            about one image format, ask for only the key it uses:
              rsa1  router images with "fw-type:" in the header  (~47 MB download)
              rsa0  Tapo camera images                           (~10 MB download)
              des   Omada / TPLink switch images                 (GPL tarball)
            Keys you skip are written as clearly-marked stub headers so that
            'make' still links; a binary built that way will fail on image
            formats whose key you stubbed.
  --verbose show binwalk output instead of hiding it.
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --keys) KEYS="${2:-}"; [ -n "$KEYS" ] || usage; shift 2 ;;
    --keys=*) KEYS="${1#*=}"; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

want() { case ",$KEYS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="rsa_key_extractor.log"

# Expected hashes. EXPECT_BOTH is upstream's combined check and is preserved when
# both RSA keys are extracted. EXPECT_RSA_1 pins RSA_1 on its own, which upstream
# could not do because it always extracted both.
EXPECT_BOTH="0a7857d40fb02ff1b8d3cbce769e6c402a82a8094b4af553c54e4ffbdc4b6e64"
EXPECT_RSA_1="66a78aa710f52f7fcc92c69926f0b136a790189be5453f38d81bed90802e7a1c"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
log_message() { printf '%b\n' "$1" | tee -a "$LOG_FILE"; }
log_info()  { log_message "${GREEN}[INFO]${RESET} $1"; }
log_warn()  { log_message "${YELLOW}[WARNING]${RESET} $1"; }
log_error() { log_message "${RED}[ERROR]${RESET} $1"; exit 1; }

# ---- portability shims -----------------------------------------------------
# macOS ships neither wget nor sha256sum, and its nm cannot read ELF objects.
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fL --retry 3 -C - -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -nc -O "$1" "$2"; }
else
  log_error "need curl or wget to download the vendor firmware."
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 | awk '{print $1}'; }
else
  log_error "need sha256sum or shasum to verify the extracted keys."
fi

pick_nm() {
  for c in nm llvm-nm gnm eu-nm; do
    if command -v "$c" >/dev/null 2>&1 && "$c" "$1" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

command -v binwalk >/dev/null 2>&1 || log_error "binwalk is not installed. Please install it and try again."
command -v xxd >/dev/null 2>&1 || log_error "xxd is not installed (part of vim)."

[ ! -d include ] && mkdir include
TMP_DIR="tmp.fwextract"
[ -d "$TMP_DIR" ] || mkdir "$TMP_DIR"
cd "$TMP_DIR"
mkdir -p fw

run_binwalk() {
  if [ "$VERBOSE" -eq 1 ]; then binwalk "$@"; else binwalk "$@" >/dev/null 2>&1; fi
}

# A stub so the C side still compiles when a key was deliberately not extracted.
stub() {
  local name="$1"
  printf 'KEY_NOT_EXTRACTED' > "$name"
  {
    echo "/* Stub: $name was not extracted (extract_keys.sh --keys did not include it)."
    echo "   Re-run extract_keys.sh with this key if you need the matching image format. */"
    xxd -i "$name"
  } > "../include/$name.h"
  log_warn "$name stubbed - binaries built now will not handle images that need it."
}

# binwalk needs external helpers (ubi_reader) to unpack UBI/UBIFS and quietly
# extracts nothing when they are missing, which looks like "key not found". If the
# key does not turn up, retry with tools/extract_rootfs.py, which carves UBI by
# magic and unpacks the volume directly.
find_in_firmware() {
  local image="$1" binary="$2" pattern="$3" found
  run_binwalk -M -e -C . "$image" || true
  found="$(find . -type f -name "$binary" -print 2>/dev/null | head -n 1)"
  if [ -z "$found" ]; then
    log_warn "binwalk did not yield $binary; falling back to tools/extract_rootfs.py"
    python3 "$SCRIPT_DIR/tools/extract_rootfs.py" "$image" -o "fallback.$binary" >&2 \
      || log_error "fallback extraction failed (pip install ubi_reader PySquashfsImage)"
    found="$(find "fallback.$binary" -type f -name "$binary" -print 2>/dev/null | head -n 1)"
  fi
  [ -n "$found" ] || return 1
  strings "$found" | grep "$pattern" | head -n 1
}

# ---- DES keys: Omada / switch firmware -------------------------------------
if want des; then
  log_info "Extracting DES keys from rtk-maple GPL release..."
  [ -f fw/rtk-maple_gpl.tar.gz ] || fetch fw/rtk-maple_gpl.tar.gz 'https://static.tp-link.com/resources/gpl/rtk-maple_gpl.tar.gz'
  tar -zxf fw/rtk-maple_gpl.tar.gz "$(tar -ztf fw/rtk-maple_gpl.tar.gz | grep libservice.so.0.0.0)"
  LIB="$(find . -type f -name 'libservice.so.0.0.0' | head -n 1)"
  [ -n "$LIB" ] || log_error "libservice.so.0.0.0 not found in the GPL tarball."
  NM="$(pick_nm "$LIB")" || log_error "no nm that can read ELF (try llvm-nm, binutils' gnm, or eu-nm)."
  DES_KEY_SYM="$(( $("$NM" "$LIB" | grep des_key | awk '{ print "0x"$1 }') - 0x10000 ))"
  DES_IV_SYM=$((DES_KEY_SYM + 8))
  dd if="$LIB" bs=1 skip="$DES_KEY_SYM" count=8 of=DES_KEY status=none 2>/dev/null \
    || dd if="$LIB" bs=1 skip="$DES_KEY_SYM" count=8 of=DES_KEY 2>/dev/null
  dd if="$LIB" bs=1 skip="$DES_IV_SYM" count=8 of=DES_IV status=none 2>/dev/null \
    || dd if="$LIB" bs=1 skip="$DES_IV_SYM" count=8 of=DES_IV 2>/dev/null
  xxd -i DES_KEY > ../include/DES_KEY.h
  xxd -i DES_IV  > ../include/DES_IV.h
  log_info "DES_KEY: $(od -An -tx1 DES_KEY | tr -d '[:space:]')"
  log_info "DES_IV:  $(od -An -tx1 DES_IV  | tr -d '[:space:]')"
else
  stub DES_KEY; stub DES_IV
fi

# ---- RSA_1: router images with "fw-type:" in the header --------------------
if want rsa1; then
  AX6000='ax6000v2-up-ver1-1-2-P1[20230731-rel41066]_1024_nosign_2023-07-31_11.26.17_1693471186048.bin.rollback'
  log_info "Extracting RSA_1 from $AX6000 ..."
  [ -f "fw/$AX6000" ] || fetch "fw/$AX6000" "http://download.tplinkcloud.com/firmware/$AX6000"
  RSAKEY_1="$(find_in_firmware "fw/$AX6000" nvrammanager BgIAAAwk)" \
    || log_error "Failed to extract RSAKEY_1."
  log_info "RSAKEY_1: $RSAKEY_1"
fi

# ---- RSA_0: Tapo camera images ---------------------------------------------
if want rsa0; then
  TAPO='Tapo_C210v1_en_1.3.1_Build_221218_Rel.73283n_u_1679534600836.bin'
  log_info "Extracting RSA_0 from $TAPO ..."
  [ -f "fw/$TAPO" ] || fetch "fw/$TAPO" "http://download.tplinkcloud.com/firmware/$TAPO"
  RSAKEY_0="$(find_in_firmware "fw/$TAPO" slpupgrade BgIAAAwk)" \
    || log_error "Failed to extract RSAKEY_0."
  log_info "RSAKEY_0: $RSAKEY_0"
fi

# ---- verify ----------------------------------------------------------------
if want rsa0 && want rsa1; then
  CALC="$(printf '%s %s' "$RSAKEY_0" "$RSAKEY_1" | sha256)"
  [ "$CALC" = "$EXPECT_BOTH" ] || log_error "Extracted RSA keys do not match the expected data. Exiting."
  log_info "Extracted RSA keys match the expected data."
elif want rsa1; then
  CALC="$(printf '%s' "$RSAKEY_1" | tr -d '\n' | sha256)"
  [ "$CALC" = "$EXPECT_RSA_1" ] || log_error "RSA_1 does not match the expected hash ($CALC)."
  log_info "RSA_1 matches the expected hash."
elif want rsa0; then
  log_warn "RSA_0 extracted but not hash-checked: upstream only pins the combined"
  log_warn "RSA_0+RSA_1 hash, so verifying it alone needs --keys rsa1,rsa0."
fi

# ---- write headers ---------------------------------------------------------
if want rsa1; then printf '%s' "$RSAKEY_1" > RSA_1; xxd -i RSA_1 > ../include/RSA_1.h; else stub RSA_1; fi
if want rsa0; then printf '%s' "$RSAKEY_0" > RSA_0; xxd -i RSA_0 > ../include/RSA_0.h; else stub RSA_0; fi

log_info "Keys written to include directory. Ready for make."
cd ..
log_info "You can remove the temporary directory with: rm -rf $TMP_DIR"
