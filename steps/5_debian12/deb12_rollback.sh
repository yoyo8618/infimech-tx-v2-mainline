#!/bin/sh
# Go back to the Debian 11 system kept as /server/tmp_deb11. Run on Tina
# (works even if Debian 12 does not start; ssh goes to Tina):
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_rollback.sh
# then power the printer off and on with its button.
# Debian 12 is kept as /server/deb12. Prints and settings made under
# Debian 12 stay there (gcodes uploaded since the switch are only in it).
R=${R:-/server}
L=$R/tmp
N=$R/deb12
OLD=$R/tmp_deb11
die() { echo "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$OLD/go.sh" ] && grep -q '^11' "$OLD/etc/debian_version" 2>/dev/null || die "no Debian 11 system in $OLD"
grep -q '^12' "$L/etc/debian_version" 2>/dev/null || die "$L is not the Debian 12 system - nothing to roll back"
[ ! -e "$N" ] || die "$N exists - nothing changed"
[ -f "$OLD/updatestm32" ] || die "updatestm32 marker missing in $OLD (go.sh would flash the stock STM32 firmware)"
sync
mv "$L" "$N" || die "renaming $L failed"
if ! mv "$OLD" "$L"; then mv "$N" "$L"; die "renaming $OLD failed - left as it was"; fi
sync
echo "/server/tmp   -> Debian $(cat "$L/etc/debian_version")"
echo "/server/deb12 -> Debian $(cat "$N/etc/debian_version") (kept)"
echo "ROLLED BACK. Now power the printer off and on with its button."
