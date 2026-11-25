#!/bin/bash
# fw_build.sh - build the Klipper STM32 firmware for the Infimech TX mainboard
# (STM32F072, USB, no bootloader) on the PC, for one Klipper version.
#
# Run in the Ubuntu (WSL) window, as your normal user (not with sudo):
#   bash ~/fw/firmware/fw_build.sh              # newest Klipper release
#   bash ~/fw/firmware/fw_build.sh v0.14.0      # a given release (or commit)
# Use the version Fluidd shows for Klipper.
#
# Output in this folder (~/fw/firmware):
#   klipper-<ver>-stm32f072-mainboard.bin       the firmware
#   klipper-<ver>-stm32f072-mainboard.bin.md5   its checksum
#   klipper-<ver>-stm32f072-mainboard.dict      its command list (checks)
#   klipper-<ver>-stm32f072-mainboard.config    the build settings used
#   build-<ver>.txt                             compiler and commit
#   fw-<ver>.tar                                all of the above plus
#                                               fw_update.sh, for the printer
# Build settings come from stm32f072-mainboard.config in this folder.
# Klipper is kept in ~/klipper-fw (fetched again at every run).
# The printer is not contacted.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$HOME/klipper-fw}
URL=https://github.com/Klipper3d/klipper.git
BASECFG=$HERE/stm32f072-mainboard.config
NAME=stm32f072-mainboard
PKGS="gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi cpp make git python3"

say() { echo; echo "$(date '+%H:%M:%S') ===== $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*"; exit 1; }

[ "$(id -u)" != 0 ] || die "run as your normal user, without sudo"
[ -f "$BASECFG" ] || die "missing $BASECFG"

say "1. tools"
# a package counts only when fully installed ("ii"), and the programs must exist
pkg_ok() { [ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" = "ii " ]; }
CMDS="arm-none-eabi-gcc arm-none-eabi-ld cpp make git python3"
missing=""
for p in $PKGS; do pkg_ok "$p" || missing="$missing $p"; done
for c in $CMDS; do
    command -v "$c" >/dev/null && continue
    case $c in
        arm-none-eabi-gcc) p=gcc-arm-none-eabi ;;
        arm-none-eabi-ld) p=binutils-arm-none-eabi ;;
        *) p=$c ;;
    esac
    echo "program missing: $c (package $p)"
    case " $missing " in *" $p "*) ;; *) missing="$missing $p" ;; esac
done
if [ -n "$missing" ]; then
    echo "installing:$missing (asks for your Ubuntu password)"
    sudo apt-get update -q && sudo apt-get install -y -q --reinstall $missing || die "install failed"
fi
bad=""
for c in $CMDS; do command -v "$c" >/dev/null || bad="$bad $c"; done
if [ -n "$bad" ]; then
    echo "still missing:$bad"
    dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' $PKGS cpp-13 2>&1
    ls -l /usr/bin/cpp* 2>&1
    die "programs missing after the install - send me this output"
fi
GCCV=$(arm-none-eabi-gcc --version | head -n 1)
echo "compiler: $GCCV"

say "2. Klipper source"
if [ ! -d "$SRC/.git" ]; then
    git clone -q "$URL" "$SRC" || die "git clone failed"
fi
git -C "$SRC" fetch -q --tags --prune origin || die "git fetch failed"
# 7-character commit names, as in the v0.14.0 build that is on the printer
git -C "$SRC" config core.abbrev 7
REF=${1:-$(git -C "$SRC" tag -l 'v*' --sort=-v:refname | head -n 1)}
[ -n "$REF" ] || die "no release found"
git -C "$SRC" -c advice.detachedHead=false checkout -q --detach "$REF^{commit}" 2>/dev/null \
    || git -C "$SRC" -c advice.detachedHead=false checkout -q --detach "origin/$REF" 2>/dev/null \
    || die "unknown Klipper version '$REF'"
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=no)" ] \
    || die "$SRC has local changes; move it away and run again"
VER=$(git -C "$SRC" describe --tags --exact-match HEAD 2>/dev/null \
      || git -C "$SRC" describe --tags --always HEAD)
LONG=$(git -C "$SRC" describe --always --tags --long --dirty)
COMMIT=$(git -C "$SRC" rev-parse HEAD)
echo "building: $VER ($LONG, commit $COMMIT)"
case $LONG in *-dirty) die "source tree is changed" ;; esac

say "3. build settings"
make -C "$SRC" -s distclean >/dev/null 2>&1
cp "$BASECFG" "$SRC/.config"
make -C "$SRC" -s olddefconfig >/dev/null || die "make olddefconfig failed"
# options that differ from the saved settings (new Klipper options get defaults)
CHG=$(diff <(grep -v '^#' "$BASECFG" | grep . | sort) <(grep -v '^#' "$SRC/.config" | grep . | sort))
if [ -z "$CHG" ]; then
    echo "settings: same as $NAME.config"
else
    echo "settings: this Klipper version changed these options ('<' saved, '>' now):"
    echo "$CHG"
fi
grep -qx 'CONFIG_MACH_STM32F072=y' "$SRC/.config" && grep -qx 'CONFIG_USBSERIAL=y' "$SRC/.config" \
    && grep -qx 'CONFIG_STM32_FLASH_START_0000=y' "$SRC/.config" && grep -qx 'CONFIG_STM32_CLOCK_REF_8M=y' "$SRC/.config" \
    && grep -qx 'CONFIG_USB_SERIAL_NUMBER_CHIPID=y' "$SRC/.config" \
    || die "build settings are not the mainboard's any more (STM32F072, USB, no bootloader, 8 MHz, chip-ID serial)"

say "4. build"
make -C "$SRC" -j"$(nproc)" > "$SRC/build.log" 2>&1 || { tail -n 30 "$SRC/build.log"; die "build failed"; }
BIN=$SRC/out/klipper.bin
DICT=$SRC/out/klipper.dict
[ -s "$BIN" ] && [ -s "$DICT" ] || die "build made no klipper.bin"
SIZE=$(stat -c %s "$BIN")
[ "$SIZE" -le 131072 ] || die "firmware is $SIZE bytes, more than the 128 KB flash"
read -r DVER DMCU DCLK < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["version"], d["config"]["MCU"], d["config"]["CLOCK_FREQ"])' "$DICT")
[ "$DVER" = "$LONG" ] || die "firmware version '$DVER' is not '$LONG'"
[ "$DMCU" = stm32f072xb ] && [ "$DCLK" = 48000000 ] || die "firmware is for $DMCU at $DCLK Hz"
echo "firmware: $SIZE bytes, version $DVER, $DMCU at $DCLK Hz"
# the firmware carries its command dictionary zlib-compressed: it must unpack
# to exactly the .dict file (the compressed bytes depend on Python's zlib)
EMB=$(python3 - "$BIN" "$DICT" <<'PYEOF'
import sys, zlib
b = open(sys.argv[1], "rb").read(); d = open(sys.argv[2], "rb").read()
for i in range(len(b) - 1):
    if b[i] == 0x78 and b[i + 1] in (0x01, 0x5e, 0x9c, 0xda):
        try:
            o = zlib.decompressobj(); out = o.decompress(b[i:])
        except zlib.error:
            continue
        if out == d:
            print("ok %d" % (len(b) - i - len(o.unused_data))); sys.exit(0)
print("missing")
PYEOF
)
case $EMB in ok*) echo "embedded command dictionary: matches the .dict (${EMB#ok } bytes compressed)" ;;
             *) die "the firmware's embedded command dictionary does not match the .dict" ;; esac
PYV=$(python3 -c 'import sys, zlib; print("Python %s, zlib %s" % (sys.version.split()[0], zlib.ZLIB_RUNTIME_VERSION))')

say "5. output"
B=klipper-$VER-$NAME
cd "$HERE" || die "cannot enter $HERE"
if [ -f "$B.bin" ]; then
    if cmp -s "$BIN" "$B.bin"; then
        echo "$B.bin already exists and is identical (the build is repeatable)"
    else
        mkdir -p _old && mv "$B.bin" "_old/$B.bin.$(date +%Y%m%d-%H%M%S)" \
            && echo "an older, different $B.bin was moved to _old/"
    fi
fi
cp "$BIN" "$B.bin"
cp "$DICT" "$B.dict"
cp "$SRC/.config" "$B.config"
md5sum "$B.bin" > "$B.bin.md5"
{
    echo "Klipper:   $VER ($LONG)"
    echo "commit:    $COMMIT"
    echo "built:     $(date '+%F %T %z') on $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "compiler:  $GCCV"
    echo "binutils:  $(arm-none-eabi-ld --version | head -n 1)"
    echo "python:    $PYV (compresses the embedded command dictionary)"
    echo "size:      $SIZE bytes"
    echo "md5:       $(cut -d' ' -f1 "$B.bin.md5")"
    echo "settings:  $NAME.config$( [ -n "$CHG" ] && echo ' (with the changes listed in the build output)')"
} > "build-$VER.txt"
FILES="$B.bin $B.bin.md5 $B.dict $B.config build-$VER.txt"
[ -f fw_update.sh ] && FILES="$FILES fw_update.sh"
tar --owner=0 --group=0 -cf "fw-$VER.tar" $FILES || die "tar failed"
cat "build-$VER.txt"
echo
echo "md5 check:  $(md5sum -c "$B.bin.md5")"
case "$(cut -d' ' -f1 "$B.bin.md5")" in
    4e09d1d47515404bbfb46408534c67d4|0682e3ea97134c1e77d558d8ae06b95e)
        echo "Known v0.14.0 build: same program and command dictionary as the firmware flashed on the printer." ;;
esac
say "done: fw-$VER.tar ($FILES)"
echo "Copy it to the printer (Command Prompt, in the firmware folder):"
echo "  ssh root@<PRINTER_IP> \"tar -xf - -C /server/tmp/home/gem/infimech/firmware\" < fw-$VER.tar"
