#!/bin/bash
# Undo step 3: moves what 3_klipper.sh created into
# /home/gem/infimech/backup/step3-undo-<time>/ (nothing is deleted).
# Only before step 4 (the printer must still boot the stock Klipper).
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/3_undo.sh"
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
G=${G:-/home/gem}
DEST=$G/infimech/backup/step3-undo-$(date +%Y%m%d-%H%M%S)
die() { echo "ERROR: $*"; echo "Nothing was changed."; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
grep -qs "boot_install.sh\|step 4" "$G/kp.sh" && die "step 4 is installed (kp.sh) - undo step 4 first (4_back_to_stock.sh)"
[ -L "$G/printer_data/config" ] && die "printer_data/config is a link (step 4) - undo step 4 first"
mkdir -p "$DEST" || die "cannot create $DEST"
for p in "$G/klipper-new" "$G/klipper-host" "$G/printer_data/config_new" "$G/infimech/klippy_extras" \
         "$G/infimech/klipper_links.sh" "$G/infimech/firmware/config.host"; do
    [ -e "$p" ] || continue
    mv "$p" "$DEST/" && echo "moved $p"
done
echo "Done. Everything step 3 made is in $DEST"
