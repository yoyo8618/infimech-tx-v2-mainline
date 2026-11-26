#!/bin/sh
# Remove /server/deb12 (the Debian 12 copy, before the switch). The running
# system (/server/tmp) is not touched.
#   ssh root@<PRINTER_IP> "sh -s" < deb12_remove.sh
R=${R:-/server}
DST=$R/deb12
die() { echo "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$DST" ] || { echo "no $DST - nothing to do"; exit 0; }
[ "$DST" != "$R/tmp" ] || die "refusing to remove the running system"
[ -f "$DST/.running" ] && die "$DST is marked as the running system - nothing removed"
# never delete through mounted /dev, /proc, /sys
umount "$R/tmp/mnt/deb12" 2>/dev/null; rmdir "$R/tmp/mnt/deb12" 2>/dev/null
for m in run sys proc dev/pts dev; do umount "$DST/$m" 2>/dev/null; done
if grep -q " $DST" /proc/mounts; then
    grep " $DST" /proc/mounts
    die "something is still mounted inside $DST - nothing removed"
fi
rm -rf "$DST"
[ -e "$DST" ] && die "could not remove everything in $DST"
echo "removed $DST; free now: $(df -k "$R" | tail -n 1 | awk '{print int($4/1024)}') MB"
