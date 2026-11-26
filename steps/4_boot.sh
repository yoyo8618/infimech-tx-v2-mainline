#!/bin/bash
# Step 4, part 1 (after step 3): prepare the switch to the new Klipper.
#  - kp.sh / local_mcu.sh (started by /run.sh at power-on) are replaced by
#    versions that look at the STM32's USB name: mainline firmware -> new
#    Klipper, stock firmware -> stock Klipper exactly as before (originals
#    kept as kp.sh.stock / local_mcu.sh.stock)
#  - Moonraker's config folder becomes the mainline one: printer_data/config
#    -> config_stock (stock Klipper keeps using it), printer_data/config is
#    a link to config_new (so Fluidd edits the config Klipper really uses)
# Nothing changes at power-on until the STM32 has the mainline firmware
# (part 2, 4_flash.sh): with the stock firmware the printer boots stock.
#
# Run inside the Debian chroot as root, printer idle:
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/4_boot.sh --check"
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/4_boot.sh" > step4_boot.txt 2>&1
# Undo: 4_back_to_stock.sh --full (on Tina)
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
G=${G:-/home/gem}
F=$G/infimech/steps/files
PD=$G/printer_data
ENV=$PD/systemd/klipper.env
OLD="$PD/config/printer.cfg"
NEWP="$PD/config_stock/printer.cfg"
MARK="Installed by /home/gem/infimech/boot_install.sh"
MOON=${MOON:-http://127.0.0.1:7125}
CHECK=0; [ "${1:-}" = --check ] && CHECK=1
say() { echo; echo "$(date '+%H:%M:%S') === $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*"; echo "Nothing more was changed."; exit 1; }
norm() { sed 's/[[:space:]]*$//' "$1" | grep -v '^$' || true; }
STOCK_KP='#!/bin/bash
cd /home/gem/klipper
source /home/gem/printer_data/systemd/klipper.env
/home/gem/klippy-env/bin/python $KLIPPER_ARGS'
STOCK_LM='#!/bin/bash
/usr/local/bin/klipper_mcu -r -I /tmp/klipper_host_mcu'

say "Step 4 part 1: boot selection and config folder$([ $CHECK = 1 ] && echo ' - CHECK ONLY')"
[ "$(id -u)" = 0 ] || die "run as root inside the chroot"
for f in "$G/klipper-new/klippy/klippy.py" "$G/klipper-host/klipper.elf" "$PD/config_new/printer.cfg" \
         "$G/infimech/klipper_links.sh" "$F/kp.sh" "$F/local_mcu.sh" "$F/which_klipper.sh"; do
    [ -e "$f" ] || die "missing $f (step 3 done? steps folder complete?)"
done
for f in "$F/kp.sh" "$F/local_mcu.sh" "$F/which_klipper.sh"; do bash -n "$f" || die "syntax error in $f"; done
BOOT_DONE=0
if grep -qs "$MARK" "$G/kp.sh" && grep -qs "$MARK" "$G/local_mcu.sh"; then
    BOOT_DONE=1; echo "boot scripts: already installed"
else
    [ "$(norm "$G/kp.sh")" = "$STOCK_KP" ] || die "$G/kp.sh is not the stock version"
    [ "$(norm "$G/local_mcu.sh")" = "$STOCK_LM" ] || die "$G/local_mcu.sh is not the stock version"
    for f in kp.sh local_mcu.sh; do
        [ -e "$G/$f.stock" ] && ! cmp -s "$G/$f" "$G/$f.stock" && die "$G/$f.stock exists and differs from $f"
    done
    echo "boot scripts: stock versions found"
fi
SWAP_DONE=0
if [ -L "$PD/config" ] && [ "$(readlink "$PD/config")" = config_new ] && [ -d "$PD/config_stock" ]; then
    SWAP_DONE=1; echo "config folder: already switched"
else
    [ -d "$PD/config" ] && [ ! -L "$PD/config" ] || die "$PD/config is not a normal folder"
    [ ! -e "$PD/config_stock" ] || die "$PD/config_stock already exists"
    [ -s "$PD/config_new/moonraker.conf" ] || die "config_new/moonraker.conf is missing"
    [ "$(grep -c -F "$OLD" "$ENV")" = 1 ] || die "unexpected $ENV (stock Klipper's start settings)"
    echo "config folder: stock layout found"
fi
state=$(python3 - "$MOON" <<'EOF'
import json, sys, urllib.request
try:
    r = urllib.request.urlopen(sys.argv[1] + "/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")
EOF
)
echo "print state: $state"
case "$state" in printing|paused) die "the printer is $state - run this when it is idle" ;; esac
if [ $CHECK = 1 ]; then say "CHECK PASSED - nothing was changed"; exit 0; fi

if [ $BOOT_DONE = 0 ]; then
    say "1. boot scripts"
    cp -p "$G/kp.sh" "$G/kp.sh.stock" && cp -p "$G/local_mcu.sh" "$G/local_mcu.sh.stock" || die "backup failed"
    install -m 755 "$F/which_klipper.sh" "$G/infimech/which_klipper.sh" || die "copy failed"
    for f in kp.sh local_mcu.sh; do
        install -m 755 "$F/$f" "$G/$f.new" && mv "$G/$f.new" "$G/$f" || die "could not install $f"
    done
    grep -qs "$MARK" "$G/kp.sh" && grep -qs "$MARK" "$G/local_mcu.sh" || die "boot scripts not as expected"
    echo "kp.sh, local_mcu.sh installed (originals: kp.sh.stock, local_mcu.sh.stock)"
fi
if [ $SWAP_DONE = 0 ]; then
    say "2. config folder"
    BK=$G/infimech/backup/step4-$(date +%Y%m%d-%H%M%S)
    mkdir -p "$BK" && cp -p "$ENV" "$BK/klipper.env" || die "backup failed"
    if [ ! -e "$PD/config_new/KAMP_Settings.cfg" ] && [ -f "$PD/config/KAMP_Settings.cfg" ]; then
        # the vendor's go.sh reinstalls KAMP into config at every boot if this file is missing
        cp -p "$PD/config/KAMP_Settings.cfg" "$PD/config_new/KAMP_Settings.cfg" && touch "$BK/kamp_settings_copied"
    fi
    sed "s#$OLD#$NEWP#" "$ENV" > "$ENV.new"
    [ "$(grep -c -F "$NEWP" "$ENV.new")" = 1 ] || { rm -f "$ENV.new"; die "could not prepare klipper.env"; }
    mv "$PD/config" "$PD/config_stock" || die "could not rename config"
    if ! ln -s config_new "$PD/config"; then
        mv "$PD/config_stock" "$PD/config"; rm -f "$ENV.new"; die "could not create the link - put back"
    fi
    mv "$ENV.new" "$ENV"
    sync
    echo "config -> $(readlink "$PD/config"); stock Klipper uses config_stock (backup: $BK)"
fi
say "DONE - part 1. Next: 4_flash.sh on Tina (not in the chroot)."
echo "Until then the printer still boots the stock Klipper with config_stock."
