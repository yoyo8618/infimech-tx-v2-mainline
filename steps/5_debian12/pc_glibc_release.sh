#!/bin/bash
# PC: install the ready-built glibc for the TX vendor kernel (GitHub release
# v0.14.0-1: libc6, libc6-dev, libc-bin, libc-dev-bin, libc-devtools,
# version 2.36-9+deb12u14+tx1) into /srv/tx/deb12 - instead of building it
# with pc_glibc.sh (about 20 minutes or more). Same result: installed, pinned,
# checked with the emulator's syscall trace.
# Only for a Debian 12 copy whose glibc is exactly 2.36-9+deb12u14; for any
# other version build it yourself with pc_glibc.sh.
#
#   put the five .deb files and SHA256SUMS from the release in one folder, then
#   sudo bash pc_glibc_release.sh <folder> 2>&1 | tee pc_glibc_release.log
set -uo pipefail
W=/srv/tx
T=$W/deb12
D=${1:-}
PKGS="libc6 libc6-dev libc-bin libc-dev-bin libc-devtools"
WANT=2.36-9+deb12u14
SUFFIX=+tx1
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; exit 1; }
umnt() { for m in dev/pts dev sys proc; do umount "$T/$m" 2>/dev/null; done; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -n "$D" ] && [ -f "$D/SHA256SUMS" ] || die "usage: pc_glibc_release.sh <folder with the .deb files and SHA256SUMS>"
grep -q '^12' "$T/etc/debian_version" 2>/dev/null || die "no Debian 12 copy in $T (run pc_build_a/b/c first)"
grep -q " $T/" /proc/mounts && die "something is mounted in $T"
VER=$(chroot "$T" dpkg-query -W -f='${Version}' libc6)
case "$VER" in
    *+tx*) die "deb12 already has a rebuilt glibc ($VER)" ;;
    "$WANT") ;;
    *) die "deb12 has glibc $VER, these packages are for $WANT - build with pc_glibc.sh instead" ;;
esac

say "1. checksums"
(cd "$D" && grep -E "_${WANT}${SUFFIX}_armhf\.deb\$" SHA256SUMS | sha256sum -c -) || die "checksum mismatch"
trap umnt EXIT
mount -t proc proc "$T/proc" && mount --bind /sys "$T/sys" && mount --bind /dev "$T/dev" \
    && mount --bind /dev/pts "$T/dev/pts" || die "mounting failed"

say "2. install into deb12 and pin"
mkdir -p "$T/home/gem/infimech/glibc-tx"
debs=""
for p in $PKGS; do
    f="$D/${p}_${WANT}${SUFFIX}_armhf.deb"
    [ -f "$f" ] || die "missing $f"
    cp "$f" "$T/home/gem/infimech/glibc-tx/"; debs="$debs /home/gem/infimech/glibc-tx/${f##*/}"
done
cp "$(dirname "$(readlink -f "$0")")/glibc_tx_edit.py" "$T/home/gem/infimech/glibc-tx/" 2>/dev/null
chroot "$T" dpkg -i $debs || die "dpkg -i failed"
cat > "$T/etc/apt/preferences.d/glibc-tx" <<PIN
# glibc rebuilt for the Infimech TX vendor kernel (see
# /home/gem/infimech/glibc-tx). Keep it: stock Debian glibc cannot start on
# that kernel. A glibc security update has to be rebuilt the same way.
Package: $PKGS
Pin: version *$SUFFIX
Pin-Priority: 1001
PIN
chroot "$T" dpkg-query -W -f='${Package} ${Version}\n' $PKGS
chroot "$T" apt-get -s upgrade 2>/dev/null | grep -E '^Inst (libc6|libc-bin)' && echo "WARNING: apt would replace it" \
    || echo "apt keeps the rebuilt glibc"

say "3. check: statx/rseq calls (must be 0)"
n=$(QEMU_STRACE=1 chroot "$T" /usr/bin/python3 -c 'import os; os.stat("/"); os.listdir("/home")' 2>&1 \
    | grep -c -E '^[0-9]+ (statx|rseq)\(')
echo "statx+rseq calls with the rebuilt glibc: $n"
[ "$n" = 0 ] || die "the glibc still calls statx or rseq"
for c in "python3 --version" "git --version" "ls -l /home"; do
    chroot "$T" sh -c "$c" > /dev/null 2>&1 && echo "ok: $c" || echo "FAILED: $c"
done
say "done - continue with pc_test.sh"
