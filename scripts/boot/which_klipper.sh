#!/bin/bash
# Prints "new" or "stock": which Klipper fits the firmware on the STM32.
# Called by kp.sh and local_mcu.sh at boot. Waits up to 20 s for the STM32
# to appear on USB:
#   new    the STM32 shows up under the [mcu] serial of config_new (the v0.14
#          firmware) and the new Klipper is installed
#   stock  the stock firmware name shows up, or nothing appears in 20 s
# Each decision is logged in /home/gem/printer_data/logs/boot_select.log
R=${INFIMECH_TEST_ROOT:-}
G=$R/home/gem
BYID=$R/dev/serial/by-id
STOCK_SERIAL=$BYID/usb-Klipper_stm32f072xb_mainboard-if00
LOG=$G/printer_data/logs/boot_select.log
WAIT=${INFIMECH_WAIT:-40}          # in half seconds

new_serial=$(awk '/^\[mcu\]/ {m=1; next} /^\[/ {m=0}
    m && /^serial[ \t]*:/ {sub(/^serial[ \t]*:[ \t]*/, ""); sub(/\r$/, "");
                           sub(/[ \t]+$/, ""); print; exit}' \
    "$G/printer_data/config_new/printer_config.cfg" 2>/dev/null)

choice=stock
why="no STM32 on USB after $((WAIT / 2)) s"
i=0
while [ $i -lt "$WAIT" ]; do
    if [ -n "$new_serial" ] && [ -e "$R$new_serial" ]; then
        if [ -f "$G/klipper-new/klippy/klippy.py" ] && [ -x "$G/klipper-host/klipper.elf" ] \
           && [ -f "$G/printer_data/config_new/printer.cfg" ] && [ -x "$G/klippy-env/bin/python" ]; then
            choice=new
            why="v0.14 firmware on USB"
        else
            why="v0.14 firmware on USB, but the new Klipper is incomplete"
        fi
        break
    fi
    if [ -e "$STOCK_SERIAL" ]; then
        why="stock firmware on USB"
        break
    fi
    sleep 0.5
    i=$((i + 1))
done
echo "$(date '+%F %T') ${1:-?}: $choice ($why)" >> "$LOG" 2>/dev/null
echo "$choice"
