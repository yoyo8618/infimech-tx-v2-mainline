#!/bin/sh
# Back to the stock Klipper and stock STM32 firmware (undo of step 4).
# Run on Tina (NOT inside the chroot), as root, printer idle:
#   ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_back_to_stock.sh"
#   ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_back_to_stock.sh --full"
# then power the printer off and on with its button (not "reboot").
#
# Default: removes Tina's "STM32 flashed" marker (/server/tmp/updatestm32).
# At the next power-on Tina's go.sh flashes the stock firmware
# (/home/gem/klipper/stm32_mainboard.bin), recreates the marker and restarts
# once more; kp.sh then sees the stock firmware and starts the stock Klipper.
# Allow 2-3 minutes. The mainline Klipper stays installed (step 4 again
# brings it back).
# --full also puts back the stock kp.sh / local_mcu.sh and the stock config
# folder layout (printer_data/config as a real folder again).
# Only for a printer still on Debian 11 (before step 5); after step 5 use
# 5_debian12/printer_rollback.sh first.
ROOT=${ROOT:-/server/tmp}
G=/home/gem
PD=$ROOT$G/printer_data
ENV=$PD/systemd/klipper.env
die() { echo "ERROR: $*"; echo "Nothing more was changed."; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$ROOT$G" ] || die "$ROOT$G not found - run this on Tina, not inside the chroot"
[ -f "$ROOT$G/klipper/stm32_mainboard.bin" ] || die "stock firmware $ROOT$G/klipper/stm32_mainboard.bin missing"
[ -f "$ROOT/update_stm32.sh" ] || die "$ROOT/update_stm32.sh (Tina's flash script) missing"

if [ "${1:-}" = --full ]; then
    for f in kp.sh local_mcu.sh; do
        [ -f "$ROOT$G/$f.stock" ] || die "$ROOT$G/$f.stock missing"
    done
    if [ -L "$PD/config" ]; then
        [ -d "$PD/config_stock" ] || die "$PD/config_stock missing"
        sed "s#$G/printer_data/config_stock/printer.cfg#$G/printer_data/config/printer.cfg#" "$ENV" > "$ENV.new"
        grep -q "$G/printer_data/config/printer.cfg" "$ENV.new" || { rm -f "$ENV.new"; die "unexpected $ENV"; }
        rm "$PD/config" && mv "$PD/config_stock" "$PD/config" && mv "$ENV.new" "$ENV" || die "could not put the config folder back"
        echo "printer_data/config is the stock folder again"
    fi
    for f in kp.sh local_mcu.sh; do
        cp -p "$ROOT$G/$f.stock" "$ROOT$G/$f" || die "could not restore $f"
    done
    echo "stock kp.sh and local_mcu.sh restored"
fi
rm -f "$ROOT/updatestm32"
sync
echo "Marker removed: at the next power-on Tina flashes the stock STM32 firmware."
echo "Power the printer off and on with its button now (it restarts once more by itself)."
