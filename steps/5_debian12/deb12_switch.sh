#!/bin/sh
# Switch the printer to Debian 12. Run on Tina (printer idle, nothing on the bed):
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_switch.sh > ~/fw/steps/5_debian12/deb12_switch.txt 2>&1
# then power the printer off and on with its button.
#
# What it does:
#  1. checks: printer idle, Debian 12 copy complete (rebuilt glibc,
#     updatestm32 marker), no old system copy in the way, enough space
#  2. stops the running Moonraker (so its database is not being written);
#     Klipper keeps running until the power cycle
#  3. copies your current data into the Debian 12 copy: configs (config_new,
#     config_stock), Moonraker database, saved variables, systemd env files,
#     HelixScreen settings, screen choice; gcodes and timelapse videos as
#     hard links (no extra space; both systems see the same files)
#  4. adds the update manager to the copied moonraker.conf, checks the copied
#     config with Klipper's offline test print
#  5. renames /server/tmp -> /server/tmp_deb11 and /server/deb12 -> /server/tmp
# The old system stays complete in /server/tmp_deb11. Way back:
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_rollback.sh   (then power cycle)
R=${R:-/server}
L=$R/tmp
N=$R/deb12
OLD=$R/tmp_deb11
G=/home/gem
PD=$G/printer_data
ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; echo "Nothing was switched. The printer runs as before (power cycle if Moonraker was stopped)."; exit 1; }
umnt() { for m in sys proc dev/pts dev; do umount "$N/$m" 2>/dev/null; done; }
inn() { chroot "$N" "$@" < /dev/null; }
[ -n "${TEST:-}" ] && inn() { echo "(TEST) chroot $*"; }

say "1. checks"
[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$L/go.sh" ] || die "$L is not the running system"
grep -q '^12' "$N/etc/debian_version" 2>/dev/null || die "no Debian 12 copy in $N"
grep -A12 '^Package: libc6$' "$N/var/lib/dpkg/status" | grep -q '^Version: .*+tx' \
    || die "the Debian 12 copy does not have the rebuilt glibc"
[ -f "$N/updatestm32" ] || die "updatestm32 marker missing in the copy (go.sh would flash the stock STM32 firmware)"
[ -f "$L/updatestm32" ] || die "updatestm32 marker missing in the running system - stop and ask"
[ ! -e "$OLD" ] || die "$OLD already exists"
grep -q " $N/" /proc/mounts && die "something is mounted in $N"
free=$(df -k "$R" | tail -n 1 | awk '{print $4}')
echo "free: $((free / 1024)) MB"
[ "$free" -ge 300000 ] || die "less than 300 MB free"
if [ -z "${TEST:-}" ]; then
    state=$(chroot "$L" python3 -c '
import json, urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")' < /dev/null)
    echo "print state: $state"
    [ "$state" = unknown ] && [ "${ALLOW_UNKNOWN:-}" = 1 ] && state=standby
    case "$state" in standby|complete|cancelled|error) ;; *) die "printer state is '$state' - run this when it is idle" ;; esac
fi
echo "checks passed"

say "2. stopping the running Moonraker"
if [ -z "${TEST:-}" ]; then
    pids=""
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "$L" ] || continue
        tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'moonraker/moonraker\.py' && pids="$pids ${p#/proc/}"
    done
    echo "Moonraker pid(s):${pids:- none}"
    [ -n "$pids" ] && kill $pids
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        alive=""; for p in $pids; do [ -d "/proc/$p" ] && alive=1; done
        [ -z "$alive" ] && break; sleep 1
    done
    [ -n "$alive" ] && { kill -9 $pids 2>/dev/null; sleep 1; }
    echo "Moonraker stopped (Klipper and the screen keep running until the power cycle)"
fi

say "3. copying your current data into Debian 12"
for p in config_new config_stock database misc certs backup systemd gcode; do
    [ -e "$L$PD/$p" ] || continue
    rm -rf "$N$PD/$p"
    cp -a "$L$PD/$p" "$N$PD/$p" || die "copy of $p failed"
    echo "  $p"
done
for f in saved_variables.cfg .moonraker.uuid moonraker.asvc; do
    [ -e "$L$PD/$f" ] && cp -a "$L$PD/$f" "$N$PD/$f" && echo "  $f"
done
grep -q -x klipper_mcu "$N$PD/moonraker.asvc" 2>/dev/null || echo klipper_mcu >> "$N$PD/moonraker.asvc"
[ -L "$N$PD/config" ] || die "printer_data/config in the copy is not the link to config_new"
for d in "$PD/gcodes" "$G/timelapse"; do
    [ -d "$L$d" ] || continue
    rm -rf "$N$d"
    cp -a -l "$L$d" "$N$d" || die "linking $d failed"
    echo "  $d (hard links: $(find "$N$d" -type f | wc -l) files)"
done
if [ -d "$L$G/helixscreen/config" ]; then
    rm -rf "$N$G/helixscreen/config"; cp -a "$L$G/helixscreen/config" "$N$G/helixscreen/config"
    echo "  helixscreen/config"
fi
cp -a "$L$G/infimech/screen.conf" "$N$G/infimech/screen.conf" 2>/dev/null && echo "  screen.conf: $(cat "$N$G/infimech/screen.conf")"
# Moonraker finds the supervisorctl stand-in in /usr/local/bin
grep -q '^export PATH=/usr/local/sbin:/usr/local/bin' "$N$G/moon.sh" \
    || sed -i '1a export PATH=/usr/local/sbin:/usr/local/bin:$PATH' "$N$G/moon.sh"
head -n 3 "$N$G/moon.sh"

say "4. moonraker.conf and an offline check of the copied config"
inn bash $G/infimech/moonraker_patch.sh $PD/config_new || die "moonraker.conf patch failed"
grep -n -E '^provider:|^\[include infimech_moonraker.conf\]' "$N$PD/config_new/moonraker.conf"
if [ -z "${TEST:-}" ]; then
    for m in dev dev/pts proc sys; do mount --bind "/$m" "$N/$m" || { umnt; die "mount $m failed"; }; done
    inn sh -c "
H=$G; T=\$H/printer_data/config_new.check-tmp
rm -rf \$T; cp -a \$H/printer_data/config_new \$T
sed -i 's/^manage_thresholds: .*/manage_thresholds: off/' \$T/infimech.cfg
cd /tmp
\$H/klippy-env/bin/python \$H/klipper-new/klippy/klippy.py \$T/printer.cfg \
    -i \$H/infimech/clean/check_print_start.gcode -o /tmp/check.out \
    -d \$H/infimech/klipper-v0.14.0-stm32f072-mainboard.dict \
    -d rpi=\$H/klipper-host/klipper.dict -l /tmp/check.log > /dev/null 2>&1
rc=\$?
echo \"exit code \$rc, unknown commands \$(grep -c 'Unknown command' /tmp/check.log), finished \$(grep -c '^Exiting (print time' /tmp/check.log)\"
rm -rf \$T /tmp/check.out* /tmp/check.log
[ \$rc = 0 ]" || { umnt; die "the offline check of the copied config failed"; }
    umnt
    grep -q " $N/" /proc/mounts && die "could not unmount everything in $N"
fi

say "5. switching"
sync
mv "$L" "$OLD" || die "renaming $L failed"
if ! mv "$N" "$L"; then
    mv "$OLD" "$L"
    die "renaming $N failed - put the old system back"
fi
date '+%F %T' > "$L/.switched-to-debian12"
sync
echo "/server/tmp      -> Debian $(cat "$L/etc/debian_version") (new)"
echo "/server/tmp_deb11 -> Debian $(cat "$OLD/etc/debian_version") (old, kept)"
df -h "$R" | tail -n 1
say "SWITCHED. Now power the printer off and on with its button."
