#!/bin/bash
# Packs the finished Debian 12 copy (/srv/tx/deb12) for the printer:
#   /srv/tx/deb12.tar.gz  and  /srv/tx/deb12.count (number of entries)
# PC only. Run after the PC test passed:
#   sudo bash ~/fw/steps/5_debian12/pc_pack.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_pack.log
set -uo pipefail
W=/srv/tx
T=$W/deb12
die() { echo "ERROR: $*"; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
grep -q '^12' "$T/etc/debian_version" 2>/dev/null || die "no Debian 12 copy in $T"
grep -q " $T/" /proc/mounts && die "something is still mounted in $T"
[ -f "$W/resolv.conf.printer" ] && cp -a "$W/resolv.conf.printer" "$T/etc/resolv.conf"
echo "resolv.conf: $(grep nameserver "$T/etc/resolv.conf")"
# leftovers from the builds and tests
rm -rf "$T"/tmp/* "$T"/tmp/.[!.]* "$T"/root/.cache "$T"/var/cache/apt/*.bin "$T"/var/lib/apt/lists/partial/*
rm -rf "$T/home/gem/printer_data/logs"/* "$T/home/gem/printer_data/comms"/*
# proc and sys must be empty; dev and run may hold a few files from the
# vendor's image (on the printer go.sh mounts over them) - shown here
for d in proc sys; do
    [ -z "$(ls -A "$T/$d" 2>/dev/null)" ] || die "$T/$d is not empty"
done
for d in dev run; do
    echo "$d: $(find "$T/$d" -mindepth 1 | wc -l) entries: $(ls -A "$T/$d" | head -n 15 | tr '\n' ' ')"
    [ -n "$(find "$T/$d" -mindepth 1 -type f -size +1M)" ] && die "$T/$d holds large files - not packing"
done
# the printer has no updatestm32 problem as long as this marker exists
[ -f "$T/updatestm32" ] || die "updatestm32 marker missing in the copy"
n=$(find "$T" -xdev | wc -l)
echo "$n" > "$W/deb12.count"
echo "entries: $n, size: $(du -sh "$T" | cut -f1)"
echo "packing (a few minutes)..."
tar -C "$T" --numeric-owner --xattrs --xattrs-include='*' -cpf - . | gzip -1 > "$W/deb12.tar.gz" || die "packing failed"
gzip -t "$W/deb12.tar.gz" || die "archive test failed"
echo "archive: $(du -h "$W/deb12.tar.gz" | cut -f1), md5 $(md5sum < "$W/deb12.tar.gz" | cut -d' ' -f1)"
echo "done"
