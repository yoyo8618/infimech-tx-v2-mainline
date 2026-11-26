#!/bin/bash
# Step 3: install mainline Klipper v0.14.0 NEXT TO the stock Klipper.
# Nothing running is changed: the stock Klipper keeps running and the
# printer keeps booting it until step 4.
#
# Run inside the Debian chroot as root, printer idle:
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/3_klipper.sh --check" > step3_check.txt 2>&1
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/3_klipper.sh" > step3.txt 2>&1
# Undo: 3_undo.sh
#
# Creates:
#   /home/gem/klipper-new            Klipper v0.14.0 (git, branch master)
#   /home/gem/klipper-host           host MCU program ("rpi"), built here
#   /home/gem/infimech/klippy_extras the two add-on modules (linked into Klipper)
#   /home/gem/infimech/firmware/config.host
#   /home/gem/printer_data/config_new  the mainline config, built from YOUR
#                                    stock config (calibration carried over)
#   /home/gem/printer_data/saved_variables.cfg (copy, if missing)
# --check builds the config into a temporary folder only and reports.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
G=${G:-/home/gem}
ST=$G/infimech/steps
F=$ST/files
NEW=$G/klipper-new
HOSTDIR=$G/klipper-host
EXT=$G/infimech/klippy_extras
FWD=$G/infimech/firmware
PY=$G/klippy-env/bin/python
CFG=$G/printer_data/config
CFG_NEW=$G/printer_data/config_new
DICT=$F/klipper-v0.14.0-stm32f072-mainboard.dict
TAG=v0.14.0
URL=https://github.com/Klipper3d/klipper.git
TS=$(date +%Y%m%d-%H%M%S)
TMP=$G/infimech/step3-config-$TS
CHECK=0; [ "${1:-}" = --check ] && CHECK=1

say() { echo; echo "$(date '+%H:%M:%S') === $*"; }
note() { echo "$(date '+%H:%M:%S') $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*"; [ -d "$TMP" ] && mv "$TMP" "$TMP.failed"; exit 1; }

say "Step 3: mainline Klipper $TAG next to stock$([ $CHECK = 1 ] && echo ' - CHECK ONLY')"
say "1. checks"
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$G/klipper/klippy/klippy.py" ] || die "stock Klipper not found in $G/klipper - run this inside the chroot (chroot /server/tmp bash ...)"
[ -d "$F/config" ] && [ -f "$F/make_config.py" ] || die "step files missing in $F - copy the whole steps folder"
[ -d "$CFG" ] && [ ! -L "$CFG" ] || die "$CFG is not the stock config folder (already switched by step 4?)"
for p in "$NEW" "$HOSTDIR" "$CFG_NEW" "$EXT"; do
    [ -e "$p" ] && die "$p already exists - step 3 was run before (3_undo.sh moves it away)"
done
for t in git gcc make python3; do command -v $t > /dev/null || die "$t is missing"; done
[ -x "$PY" ] || die "$PY missing"
"$PY" -c "import cffi, greenlet, jinja2, serial" 2>/dev/null || die "the Klipper Python environment lacks cffi/greenlet/jinja2/pyserial"
note "Python: $("$PY" -c 'import sys; print(sys.version.split()[0])')"
FREE=$(df -Pm "$G" | awk 'NR == 2 {print $4}')
[ "${FREE:-0}" -ge 400 ] || die "only ${FREE:-?} MB free in $G (need 400)"
note "free space: $FREE MB"
note "stock config: $(head -n 1 "$CFG/printer_config.cfg") / $(head -n 1 "$CFG/printer.cfg")"

say "2. building the mainline config from your stock config (into a temporary folder)"
mkdir -p "$TMP.tpl" || die "cannot create $TMP.tpl"
cp "$F"/config/*.cfg "$F"/vendor_expected/*.txt "$TMP.tpl/"
python3 "$F/make_config.py" --home "$G" --old "$CFG" --templates "$TMP.tpl" --out "$TMP" --diff "$G/infimech/step3-config.diff"
rc=$?
rm -rf "$TMP.tpl"
if [ $rc != 0 ]; then
    [ -f "$G/infimech/step3-config.diff" ] && { echo "--- differences from the known vendor config:"; head -n 80 "$G/infimech/step3-config.diff"; }
    echo
    echo "Your stock config is not a known vendor version (v1.0.15, v1.0.17, v1.0.18, v1.0.20),"
    echo "or its hardware part was changed."
    echo "Nothing was changed. Please send step3_check.txt and $G/infimech/step3-config.diff"
    echo "(it contains no personal data except your printer's own calibration values)."
    exit 1
fi
SV_SRC=$(sed -n 's/^filename[ \t]*[:=][ \t]*//p' "$CFG/printer_config.cfg" | head -n 1)

if [ $CHECK = 1 ]; then
    rm -rf "$TMP"
    say "CHECK PASSED - nothing was changed"
    echo "Without --check this would download Klipper $TAG (needs internet), build the host"
    echo "MCU program (a few minutes) and create config_new. The stock Klipper keeps running."
    exit 0
fi

say "3. Klipper $TAG (full git history, branch master; a few minutes)"
git clone -q "$URL" "$NEW" || die "git clone failed (internet?)"
git -C "$NEW" -c advice.detachedHead=false checkout -q -B master "$TAG" || die "checkout of $TAG failed"
git -C "$NEW" branch -q -u origin/master master || die "could not set the upstream branch"
note "Klipper: $(git -C "$NEW" describe --tags --long --always)"

say "4. add-on modules"
mkdir -p "$EXT" "$G/infimech/backup" && cp "$F"/klippy_extras/*.py "$EXT/" || die "copy failed"
install -m 755 "$F/klipper_links.sh" "$G/infimech/klipper_links.sh" || die "copy failed"
mkdir -p "$HOSTDIR"     # klipper_links.sh links klipper-new/out-host to it
env G="$G" bash "$G/infimech/klipper_links.sh"
for f in "$EXT"/*.py; do [ -L "$NEW/klippy/extras/${f##*/}" ] || die "could not link ${f##*/}"; done
note "linked: $(cd "$EXT" && echo *.py)"
# files later steps use for offline checks
mkdir -p "$G/infimech/clean" && cp "$F/check_print_start.gcode" "$G/infimech/clean/" && cp "$DICT" "$G/infimech/" || die "copy failed"

say "5. Klipper's C helper (a few minutes)"
"$PY" -c "import sys; sys.path.insert(0, '$NEW/klippy'); import chelper; chelper.get_ffi(); print('chelper OK')" \
    || die "C helper build failed"

say "6. host MCU program into $HOSTDIR (a few minutes)"
mkdir -p "$FWD"
[ -f "$FWD/config.host" ] || printf 'CONFIG_MACH_LINUX=y\n' > "$FWD/config.host"
cp "$FWD/config.host" "$HOSTDIR/config.host"
{ make -C "$NEW" KCONFIG_CONFIG="$HOSTDIR/config.host" OUT="$HOSTDIR/" olddefconfig \
  && make -C "$NEW" KCONFIG_CONFIG="$HOSTDIR/config.host" OUT="$HOSTDIR/" -j"$(nproc)"; } \
    > "$HOSTDIR/build.log" 2>&1 || { tail -n 25 "$HOSTDIR/build.log"; die "host MCU build failed"; }
[ -x "$HOSTDIR/klipper.elf" ] && [ -f "$HOSTDIR/klipper.dict" ] || die "the build made no klipper.elf"
note "built $(python3 -c "import json; print(json.load(open('$HOSTDIR/klipper.dict'))['version'])")"

say "7. config_new"
[ -d "$TMP" ] || die "the config built in part 2 is missing ($TMP)"
mv -T "$TMP" "$CFG_NEW" || die "could not create $CFG_NEW"
note "$CFG_NEW: $(cd "$CFG_NEW" && echo *)"
SV=$G/printer_data/saved_variables.cfg
if [ ! -f "$SV" ] && [ -n "$SV_SRC" ] && [ -f "$SV_SRC" ]; then
    cp -p "$SV_SRC" "$SV" && note "saved variables copied from $SV_SRC"
fi
[ -f "$SV" ] || { : > "$SV"; note "created an empty $SV"; }

say "8. offline config check: a test print in batch mode (no hardware used)"
CT=$G/infimech/step3-check-tmp
rm -rf "$CT" && cp -a "$CFG_NEW" "$CT"
sed -i 's/^manage_thresholds: .*/manage_thresholds: off/' "$CT/infimech.cfg"   # no bed sensor in batch mode
# In batch mode the probe "touches" at stepper_z position_min, so the simulated
# mesh sits at position_min minus z_offset and the wipe moves would go below
# position_min ("Move out of range"). The test copy uses z_offset -1 to keep
# them in range; the real config keeps the owner's value.
sed -i 's/^z_offset: .*/z_offset: -1/' "$CT/printer.cfg"
(cd "$NEW" && "$PY" klippy/klippy.py "$CT/printer.cfg" -i "$G/infimech/clean/check_print_start.gcode" -o /dev/null \
    -d "$DICT" -d "rpi=$HOSTDIR/klipper.dict" -l "$G/infimech/step3_check.log" > /dev/null 2>&1)
rc=$?
rm -rf "$CT"
[ $rc = 0 ] || { grep -a -E "^(Config error|Error)|error|out of range" "$G/infimech/step3_check.log" | tail -n 15; die "offline check failed (exit $rc), log: $G/infimech/step3_check.log"; }
note "offline check passed"

say "DONE - Klipper $TAG is installed next to stock. Nothing running was changed."
echo "Next: step 4 (flash the STM32 and switch to the new Klipper at power-on)."
