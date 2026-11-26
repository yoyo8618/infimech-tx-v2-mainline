#!/bin/sh
# Step 4, part 2 (after 4_boot.sh): flash the mainline Klipper v0.14.0
# firmware into the STM32 mainboard, then power-cycle.
#
# Run on Tina (NOT inside the chroot), as root, printer idle:
#   ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_flash.sh --check"
#   ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_flash.sh" > step4_flash.txt 2>&1
# then power the printer off and on with its button (not "reboot").
#
# What it does:
#  1. stops the stock Klipper and the stock host MCU program
#     (Moonraker, Fluidd and the screen keep running)
#  2. puts the STM32 into its ROM bootloader (BOOT0 = GPIO228 high, reset
#     pulse on GPIO142, the same sequence as Tina's update_stm32.sh), writes
#     the firmware with dfu-util, reads it back and compares, restarts it
#  3. writes the board's new USB name (it contains the chip ID) into
#     config_new/printer_config.cfg [mcu] serial
# At the next power-on kp.sh sees the mainline firmware and starts the new
# Klipper. Way back: 4_back_to_stock.sh (Tina reflashes the stock firmware).
# The firmware file must be in /home/gem/infimech/firmware/ (from the
# GitHub release, or built with scripts/fw_build.sh).
ROOT=${ROOT:-/server/tmp}
G=/home/gem
FWD=$G/infimech/firmware
FWNAME=klipper-v0.14.0-stm32f072-mainboard.bin
FW=$FWD/$FWNAME
NEW=$G/klipper-new
MCU_CFG=$G/printer_data/config_new/printer_config.cfg
BYID=${BYID:-/dev/serial/by-id}
STOCK_SERIAL=$BYID/usb-Klipper_stm32f072xb_mainboard-if00
GPIO=${GPIO:-/sys/class/gpio}
BOOT0=228
RESET=142
CHECK=0; [ "${1:-}" = --check ] && CHECK=1

say() { echo; echo "$(date '+%H:%M:%S') === $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*"; exit 1; }
inroot() { chroot "$ROOT" "$@"; }
pids_of() {   # PIDs whose command line contains $1
    for d in /proc/[0-9]*; do
        c=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline") || continue
        case "$c" in *"$1"*) echo "${d#/proc/}" ;; esac
    done
}
stop_pids() {
    what=$1; shift
    [ -n "$*" ] || { echo "$what: not running"; return 0; }
    echo "$what: stopping PID(s) $*"
    kill "$@" 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        alive=""
        for p in "$@"; do [ -d /proc/$p ] && alive="$alive $p"; done
        [ -z "$alive" ] && { echo "$what: stopped"; return 0; }
        sleep 1
    done
    echo "$what: still running, forcing"
    kill -9 $alive 2>/dev/null
    sleep 1
}
gpio_setup() {  # <num> <high|low>: output with a defined level, no glitch
    [ -d "$GPIO/gpio$1" ] || echo "$1" > "$GPIO/export"
    echo "$2" > "$GPIO/gpio$1/direction"
}
reset_stm32() {  # <boot0 value>
    gpio_setup $RESET high
    gpio_setup $BOOT0 low
    echo "$1" > "$GPIO/gpio$BOOT0/value"
    echo 0 > "$GPIO/gpio$RESET/value"
    sleep 0.1
    echo 1 > "$GPIO/gpio$RESET/value"
}
dfu_present() { inroot dfu-util -l 2>/dev/null | grep -q '0483:df11'; }
new_serial() {   # the mainline firmware's USB name (anything but "mainboard")
    for s in "$BYID"/usb-Klipper_stm32f072xb_*-if00; do
        [ -e "$s" ] && [ "$s" != "$STOCK_SERIAL" ] && echo "$s"
    done
}
mask() { sed 's/\(stm32f072xb_\)[0-9A-Fa-f]*/\1<chip id>/g'; }
print_state() {
    inroot python3 -c '
import json, urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")'
}

say "Step 4 part 2: flash the STM32$([ $CHECK = 1 ] && echo ' - CHECK ONLY')"
[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$ROOT$G" ] || die "$ROOT$G not found - run this on Tina, not inside the chroot"
grep -qs "boot_install.sh" "$ROOT$G/kp.sh" || die "run 4_boot.sh first"
for f in "$FW" "$FW.md5" "$NEW/klippy/klippy.py" "$G/klipper-host/klipper.elf" "$MCU_CFG" \
         "$G/klipper/stm32_mainboard.bin" "/update_stm32.sh"; do
    [ -f "$ROOT$f" ] || die "missing $ROOT$f"
done
(cd "$ROOT$FWD" && md5sum -c "$FWNAME.md5") || die "firmware checksum mismatch"
KV=$(inroot git -C "$NEW" describe --tags --always 2>/dev/null)
case "$KV" in v0.14.0*) ;; *) die "Klipper in $NEW is '$KV', but this firmware is v0.14.0" ;; esac
for t in dfu-util python3 cmp; do inroot sh -c "command -v $t" > /dev/null || die "$t missing in the chroot (apt install it)"; done
[ -w "$GPIO/export" ] || die "$GPIO/export not writable"
[ -f "$ROOT/updatestm32" ] || die "$ROOT/updatestm32 (Tina's 'STM32 flashed' marker) is missing - at the next boot Tina would flash the stock firmware"
FWSIZE=$(wc -c < "$ROOT$FW" | tr -d ' ')
echo "firmware:       $FWNAME ($FWSIZE bytes, md5 OK), Klipper $KV"
STOCK_KLIPPY=$(pids_of "$G/klipper/klippy/klippy.py")
STOCK_MCU=$(pids_of "/usr/local/bin/klipper_mcu")
echo "stock klippy:   ${STOCK_KLIPPY:-not running}"
echo "stock host MCU: ${STOCK_MCU:-not running}"
if [ -e "$STOCK_SERIAL" ]; then
    echo "STM32 on USB:   stock firmware"
elif [ -n "$(new_serial)" ]; then
    echo "STM32 on USB:   $(new_serial | mask) (mainline firmware already?) - it will be flashed again"
elif dfu_present; then
    echo "STM32 on USB:   in its ROM bootloader (an earlier flash did not finish) - it will be flashed"
else
    die "the STM32 is not on USB"
fi
if [ -n "$STOCK_KLIPPY" ]; then
    STATE=$(print_state); echo "print state:    $STATE"
    case "$STATE" in
        printing|paused) die "the printer is $STATE - finish or cancel the print first" ;;
        unknown) [ "${FORCE:-0}" = 1 ] || die "cannot read the print state (FORCE=1 to go on)" ;;
    esac
fi
if [ $CHECK = 1 ]; then
    say "CHECK PASSED - nothing was changed"
    echo "Without --check: stop stock Klipper, flash + verify the STM32, set its new USB name in config_new."
    exit 0
fi

say "1. stopping stock Klipper (Moonraker, Fluidd and the screen keep running)"
stop_pids "stock klippy" $STOCK_KLIPPY
stop_pids "stock host MCU" $STOCK_MCU
[ -z "$(pids_of "$G/klipper/klippy/klippy.py")$(pids_of /usr/local/bin/klipper_mcu)" ] \
    || die "stock Klipper did not stop - nothing was flashed. Power-cycle to return to normal."

say "2. flashing the STM32"
echo "entering the ROM bootloader (BOOT0 high, reset pulse)"
reset_stm32 1
sleep 0.5
i=0
until dfu_present; do i=$((i + 1)); [ $i -ge 20 ] && break; sleep 0.5; done
if ! dfu_present; then
    reset_stm32 0
    die "the STM32 did not appear in DFU mode; it was restarted with its old firmware. Power-cycle to return to normal."
fi
echo "DFU device found, writing $FWNAME"
inroot dfu-util -d 0483:df11 -a 0 -s 0x08000000 -D "$FW" > "$ROOT$FWD/step4_flash.log" 2>&1 || {
    tail -n 15 "$ROOT$FWD/step4_flash.log"
    die "write failed. The STM32 stays in its ROM bootloader (safe, outputs off). Run this script again, or 4_back_to_stock.sh and power-cycle."; }
echo "reading back and comparing"
RB=/tmp/step4_readback.bin
rm -f "$ROOT$RB"
inroot dfu-util -d 0483:df11 -a 0 -s 0x08000000:"$FWSIZE" -U "$RB" >> "$ROOT$FWD/step4_flash.log" 2>&1 \
    || die "read-back failed. The STM32 stays in its ROM bootloader (safe). Run this script again."
inroot cmp "$FW" "$RB" || die "VERIFY FAILED. The STM32 stays in its ROM bootloader (safe). Run this script again."
echo "verify OK ($FWSIZE bytes identical)"
echo "starting the new firmware (BOOT0 low, reset pulse)"
reset_stm32 0
sleep 0.5
echo $BOOT0 > "$GPIO/unexport" 2>/dev/null
echo $RESET > "$GPIO/unexport" 2>/dev/null
i=0
until [ -n "$(new_serial)" ]; do
    i=$((i + 1))
    [ $i -ge 30 ] && { ls "$BYID" 2>&1 | mask; die "the STM32 did not come back on USB with the mainline firmware. Power-cycle and send me this output."; }
    sleep 0.5
done
SER=$(new_serial)
[ "$(echo "$SER" | grep -c .)" = 1 ] || die "more than one Klipper board on USB: $(echo $SER | mask)"
echo "STM32 is back on USB: $(echo "$SER" | mask)"

say "3. writing the USB name into config_new"
cp -p "$ROOT$MCU_CFG" "$ROOT$MCU_CFG.bak-step4"
awk -v s="$SER" '/^\[mcu\]/ {m=1} /^\[/ && !/^\[mcu\]/ {m=0}
     m && /^serial[ \t]*:/ {print "serial: " s; next} {print}' "$ROOT$MCU_CFG.bak-step4" > "$ROOT$MCU_CFG.new"
grep -q "^serial: $SER\$" "$ROOT$MCU_CFG.new" || die "could not set the serial (config unchanged)"
mv "$ROOT$MCU_CFG.new" "$ROOT$MCU_CFG"
sync
echo "[mcu] serial set (old file: printer_config.cfg.bak-step4)"
say "DONE - power the printer off and on with its button now."
echo "At power-on the new Klipper starts (logged in printer_data/logs/boot_select.log)."
echo "Way back: sh /server/tmp/home/gem/infimech/steps/4_back_to_stock.sh, then power-cycle."
