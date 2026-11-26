#!/bin/sh
# Remove /server/tmp_deb11, the old Debian 11 system kept after the switch
# to Debian 12. Only after a checked snapshot of it is on the PC:
# pc_snapshot.sh writes the marker /server/tmp_deb11/.snapshot_ok.
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/deb11_remove.sh
# The running system (/server/tmp, Debian 12) is not touched.
# After this, deb12_rollback.sh no longer works; going back to Debian 11
# means restoring the snapshot first (see steps/README.md).
R=${R:-/server}
OLD=$R/tmp_deb11
L=$R/tmp
die() { echo "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$OLD" ] || { echo "no $OLD - nothing to do"; exit 0; }
[ "$OLD" != "$L" ] || die "refusing to remove the running system"
grep -q '^11' "$OLD/etc/debian_version" 2>/dev/null || die "$OLD is not a Debian 11 system - nothing removed"
grep -q '^12' "$L/etc/debian_version" 2>/dev/null || die "$L is not Debian 12 - nothing removed"
[ -f "$OLD/.snapshot_ok" ] || die "no snapshot marker in $OLD - run pc_snapshot.sh first"
echo "snapshot: $(cat "$OLD/.snapshot_ok")"
for p in /proc/[0-9]*; do
    [ "$(readlink "$p/root" 2>/dev/null)" = "$OLD" ] && die "a program is running inside $OLD (pid ${p#/proc/}) - nothing removed"
done
if grep -q " ${OLD}[/ ]" /proc/mounts; then
    grep " ${OLD}[/ ]" /proc/mounts
    die "something is mounted inside $OLD - nothing removed"
fi
before=$(df -k "$R" | tail -n 1 | awk '{print int($4/1024)}')
rm -rf "$OLD"
[ -e "$OLD" ] && die "could not remove everything in $OLD"
sync
echo "removed $OLD; free on $R: $before MB -> $(df -k "$R" | tail -n 1 | awk '{print int($4/1024)}') MB"
