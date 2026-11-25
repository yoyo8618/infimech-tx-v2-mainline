#!/bin/bash
# Starts the host ("rpi") MCU program at boot (run from /run.sh).
# Installed by /home/gem/infimech/boot_install.sh; the stock version is local_mcu.sh.stock.
# Starts the v0.14 program when the STM32 has the v0.14 firmware, else stock.
R=${INFIMECH_TEST_ROOT:-}
G=/home/gem
if [ "$(bash $R$G/infimech/which_klipper.sh host_mcu)" = new ]; then
    renice -n -20 -p $$ >/dev/null 2>&1
    exec $R$G/klipper-host/klipper.elf -r -I /tmp/klipper_host_mcu
fi
exec bash $R$G/local_mcu.sh.stock
