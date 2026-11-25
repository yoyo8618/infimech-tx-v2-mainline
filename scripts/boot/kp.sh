#!/bin/bash
# Starts Klipper at boot (run from /run.sh).
# Installed by /home/gem/infimech/boot_install.sh; the stock version is kp.sh.stock.
# Starts the v0.14 Klipper when the STM32 has the v0.14 firmware, else stock.
R=${INFIMECH_TEST_ROOT:-}
G=/home/gem
if [ "$(bash $R$G/infimech/which_klipper.sh klippy)" = new ]; then
    # touchscreen: HelixScreen when infimech/screen.conf says helix (screen.sh)
    [ "$(cat $R$G/infimech/screen.conf 2>/dev/null)" = helix ] && setsid -f bash $R$G/infimech/screen/helix_run.sh boot > /dev/null 2>&1 < /dev/null
    cd $R$G/klipper-new
    G=$R$G bash $R$G/infimech/klipper_links.sh > /dev/null 2>&1
    renice -n -20 -p $$ >/dev/null 2>&1
    exec $R$G/klippy-env/bin/python $G/klipper-new/klippy/klippy.py $G/printer_data/config_new/printer.cfg -I $G/printer_data/comms/klippy.serial -l $G/printer_data/logs/klippy.log -a $G/printer_data/comms/klippy.sock
fi
exec bash $R$G/kp.sh.stock
