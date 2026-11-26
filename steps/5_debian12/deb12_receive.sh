#!/bin/sh
# Printer side: unpacks the Debian 12 system sent from the PC into
# /server/deb12, next to the running system. The running system is not
# changed (a temporary folder /server/tmp/mnt/deb12 is used for unpacking
# with the running Debian's tar, and removed again).
# From the Ubuntu window on the PC:
#   ssh root@<PRINTER_IP> "cat > /server/deb12_receive.sh" < ~/fw/steps/5_debian12/deb12_receive.sh
#   ssh root@<PRINTER_IP> "sh /server/deb12_receive.sh $(cat /srv/tx/deb12.count)" < /srv/tx/deb12.tar.gz
R=/server
L=$R/tmp
N=$R/deb12
M=$L/mnt/deb12
EXPECT=${1:-0}
die() { echo "ERROR: $*"; exit 1; }
cleanup() { umount "$M" 2>/dev/null; rmdir "$M" 2>/dev/null; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$L/go.sh" ] && [ -x "$L/bin/tar" -o -x "$L/usr/bin/tar" ] || die "$L is not the running Debian system"
[ ! -e "$N" ] || die "$N already exists - remove it first:  ssh root@<PRINTER_IP> \"sh -s\" < deb12_remove.sh"
free=$(df -k "$R" | tail -n 1 | awk '{print $4}')
echo "free: $((free / 1024)) MB"
[ "$free" -ge 2600000 ] || die "less than 2.6 GB free - stopped"
grep -q " $M " /proc/mounts && die "$M is mounted already"
mkdir "$N" && chmod 755 "$N" && mkdir -p "$M" || die "cannot create folders"
trap cleanup EXIT
mount --bind "$N" "$M" || die "bind mount failed"
echo "$(date '+%H:%M:%S') unpacking (5-20 minutes over Wi-Fi)..."
chroot "$L" tar --numeric-owner --xattrs --xattrs-include='*' -xpzf - -C /mnt/deb12
rc=$?
echo "$(date '+%H:%M:%S') tar exit code: $rc"
n=$(chroot "$L" find /mnt/deb12 -xdev | wc -l)
echo "entries: $n (expected $EXPECT)"
cleanup
trap - EXIT
[ $rc = 0 ] || die "unpacking failed - remove the partial copy with deb12_remove.sh and try again"
[ "$EXPECT" = 0 ] || [ "$n" = "$EXPECT" ] || die "entry count differs - remove the copy with deb12_remove.sh and try again"
[ -f "$N/updatestm32" ] && echo "updatestm32 marker: present" || echo "WARNING: updatestm32 marker missing"
echo "debian: $(cat "$N/etc/debian_version")"
echo "free now: $(( $(df -k "$R" | tail -n 1 | awk '{print $4}') / 1024 )) MB"
echo "RECEIVED OK"
