#!/bin/bash
# PC: Debian 12's C library (glibc 2.36) rebuilt for the printer's vendor
# kernel, where system call 397 (statx on newer kernels) and 398 (rseq) are
# vendor calls that answer EINVAL, so stock Debian 12 programs cannot start.
# Changes (glibc_tx_edit.py): stat family uses fstatat64 on 32-bit ARM,
# statx() is emulated, rseq is off by default.
#
#  1. copies /srv/tx/deb12 to /srv/tx/gbuild (build area; deb12 stays clean)
#  2. downloads Debian's glibc source for the version installed in deb12,
#     applies the edits, builds the packages (ARM emulator; long)
#  3. installs them into /srv/tx/deb12, pins them (apt keeps them)
#  4. checks with the emulator's syscall trace that no statx/rseq calls are
#     left, and packs the changed files: /srv/tx/glibc-tx-update.tar.gz
# PC only; the printer is not contacted.
#
#   sudo bash ~/fw/pc_glibc.sh 2>&1 | tee ~/fw/pc_glibc.log
#   (start over: sudo REDO=1 bash ~/fw/pc_glibc.sh ...)
set -uo pipefail
W=/srv/tx
T=$W/deb12
B=$W/gbuild
OUT=$W/glibc-tx
SUFFIX=+tx1
EDIT=${EDIT:-$HOME/fw/glibc_tx_edit.py}
[ -f "$EDIT" ] || EDIT=$(dirname "$(readlink -f "$0")")/glibc_tx_edit.py
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C

ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; exit 1; }
umnt() { for m in dev/pts dev sys proc; do umount "$1/$m" 2>/dev/null; done; }
mnt() { mount -t proc proc "$1/proc" && mount --bind /sys "$1/sys" && mount --bind /dev "$1/dev" \
        && mount --bind /dev/pts "$1/dev/pts"; }
cleanup() {
    umnt "$B"; umnt "$T"
    [ -f "$W/resolv.conf.printer" ] && cp -a "$W/resolv.conf.printer" "$T/etc/resolv.conf"
}

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -f "$EDIT" ] || die "glibc_tx_edit.py not found (put it next to this script)"
grep -q '^12' "$T/etc/debian_version" 2>/dev/null || die "no Debian 12 copy in $T"
grep -q " $T/" /proc/mounts && die "something is mounted in $T"
START=$(date +%s)
VER=$(chroot "$T" dpkg-query -W -f='${Version}' libc6)
case "$VER" in *+tx*) die "deb12 already has the rebuilt glibc ($VER)" ;; esac
# arch-specific glibc packages only (locales and libc-l10n are arch "all" and stay stock)
PKGS=$(chroot "$T" dpkg-query -W -f='${Package} ${db:Status-Abbrev} ${source:Package} ${Architecture}\n' \
       | awk '$2 == "ii" && $3 == "glibc" && $4 != "all" {print $1}' | tr '\n' ' ')
echo "glibc version in deb12: $VER"
echo "glibc packages installed in deb12: $PKGS"

say "1. build area"
if [ -e "$B" ]; then
    [ "${REDO:-}" = 1 ] || [ ! -e "$B/build" ] || echo "(reusing $B; REDO=1 starts it fresh)"
    umnt "$B"; grep -q " $B/" /proc/mounts && die "something is still mounted in $B"
    [ "${REDO:-}" = 1 ] && { rm -rf "$B"; echo "old build area removed"; }
fi
if [ ! -e "$B" ]; then cp -a "$T" "$B" || die "copy failed"; fi
rm -f "$B/etc/dpkg/dpkg.cfg.d/01-printer-nodoc"
mnt "$B" || { cleanup; die "mounting failed"; }
trap cleanup EXIT
cp -L /etc/resolv.conf "$B/etc/resolv.conf"
cat > "$B/etc/apt/sources.list.d/deb-src.list" <<'EOF'
deb-src http://deb.debian.org/debian bookworm main
deb-src http://deb.debian.org/debian bookworm-updates main
deb-src http://deb.debian.org/debian-security bookworm-security main
EOF

say "2. tools and glibc's build dependencies (in the build area only)"
chroot "$B" apt-get update > /dev/null || die "apt update failed"
chroot "$B" apt-get install -y --no-install-recommends build-essential fakeroot devscripts dpkg-dev \
    > "$W/glibc-deps.log" 2>&1 || { tail -n 20 "$W/glibc-deps.log"; die "tool install failed"; }
chroot "$B" apt-get build-dep -y glibc >> "$W/glibc-deps.log" 2>&1 \
    || { tail -n 20 "$W/glibc-deps.log"; die "build-dep failed"; }
echo "ok"

say "3. source"
if ! ls -d "$B"/build/glibc-2.36*/debian > /dev/null 2>&1; then
    mkdir -p "$B/build"
    chroot "$B" sh -c "cd /build && apt-get source glibc=$VER" > "$W/glibc-source.log" 2>&1 \
        || { tail -n 15 "$W/glibc-source.log"; die "source $VER not available (Debian may have a newer glibc; tell Claude)"; }
fi
SRC=$(ls -d "$B"/build/glibc-2.36*/ | head -n 1); SRC=${SRC%/}
echo "source: ${SRC#$B}"
python3 "$EDIT" "$SRC" || die "source edits failed"
if ! head -n 1 "$SRC/debian/changelog" | grep -q -- "$SUFFIX"; then
    chroot "$B" sh -c "cd ${SRC#$B} && DEBEMAIL=printer@localhost DEBFULLNAME='Infimech TX' \
        dch -v '$VER$SUFFIX' -D bookworm --force-distribution \
        'Infimech TX vendor kernel 4.9: no statx/rseq system calls (397/398 are vendor calls there).'" \
        || die "changelog failed"
fi
head -n 1 "$SRC/debian/changelog"

say "4. build (ARM emulator, $(nproc) threads; this is the long part)"
if ! ls "$B"/build/libc6_*"$SUFFIX"_armhf.deb > /dev/null 2>&1; then
    chroot "$B" sh -c "cd ${SRC#$B} && DEB_BUILD_OPTIONS='nocheck nodoc parallel=$(nproc)' \
        dpkg-buildpackage -B -uc -us -Pnocheck,nodoc" > "$W/glibc-build.log" 2>&1
    rc=$?
    echo "build exit code $rc ($(( ($(date +%s) - START) / 60 )) minutes so far)"
    [ $rc = 0 ] || { grep -n -E 'error|Error' "$W/glibc-build.log" | tail -n 25; die "build failed (log: $W/glibc-build.log)"; }
fi
mkdir -p "$OUT"; cp "$B"/build/*"$SUFFIX"*.deb "$OUT/"
ls -l "$OUT"

say "5. control check: stock glibc (build area) - statx/rseq calls seen"
QEMU_STRACE=1 chroot "$B" /usr/bin/python3 -c 'import os; os.stat("/")' 2>&1 \
    | grep -c -E '^[0-9]+ (statx|rseq)\(' | sed 's/^/statx+rseq calls with stock glibc: /'
umnt "$B"

say "6. install into deb12"
mnt "$T" || die "mounting deb12 failed"
cp -L /etc/resolv.conf "$T/etc/resolv.conf"
mkdir -p "$T/home/gem/infimech/glibc-tx"
debs=""
for p in $PKGS; do
    f=$(ls "$OUT"/${p}_*"$SUFFIX"_*.deb 2>/dev/null | head -n 1)
    [ -n "$f" ] || die "no rebuilt package for $p"
    cp "$f" "$T/home/gem/infimech/glibc-tx/"; debs="$debs /home/gem/infimech/glibc-tx/${f##*/}"
done
cp "$EDIT" "$T/home/gem/infimech/glibc-tx/"
chroot "$T" dpkg -i $debs || die "dpkg -i failed"
cat > "$T/etc/apt/preferences.d/glibc-tx" <<EOF
# glibc rebuilt for the Infimech TX vendor kernel (see
# /home/gem/infimech/glibc-tx). Keep it: stock Debian glibc cannot start on
# that kernel. A glibc security update has to be rebuilt the same way.
Package: $PKGS
Pin: version *$SUFFIX
Pin-Priority: 1001
EOF
chroot "$T" dpkg-query -W -f='${Package} ${Version}\n' $PKGS
chroot "$T" apt-get -s upgrade 2>/dev/null | grep -E '^Inst (libc6|libc-bin)' && echo "WARNING: apt would replace it" \
    || echo "apt keeps the rebuilt glibc"

say "7. check: rebuilt glibc in deb12 - statx/rseq calls seen (must be 0)"
n=$(QEMU_STRACE=1 chroot "$T" /usr/bin/python3 -c 'import os; os.stat("/"); os.listdir("/home")' 2>&1 \
    | grep -c -E '^[0-9]+ (statx|rseq)\(')
echo "statx+rseq calls with rebuilt glibc: $n"
[ "$n" = 0 ] || die "the rebuilt glibc still calls statx or rseq"
for c in "python3 --version" "/home/gem/klippy-env/bin/python -c 'import greenlet, cffi, numpy'" \
         "/home/gem/moonraker-env/bin/python -c 'import tornado, lmdb'" "git --version" "nginx -t" "ls -l /home"; do
    chroot "$T" sh -c "$c" > /dev/null 2>&1 && echo "ok: $c" || echo "FAILED: $c"
done

say "8. update package for the printer"
L=$W/glibc-tx.files
{
    for p in $PKGS; do chroot "$T" dpkg -L "$p"; done | while read -r f; do
        [ -L "$T$f" ] || [ -f "$T$f" ] && echo ".$f"
    done
    for f in "$T"/var/lib/dpkg/info/*; do
        n=${f##*/}; for p in $PKGS; do case "$n" in "$p".*|"$p":*) echo "./var/lib/dpkg/info/$n" ;; esac; done
    done
    echo ./var/lib/dpkg/status
    echo ./etc/ld.so.cache
    echo ./etc/apt/preferences.d/glibc-tx
    echo ./home/gem/infimech/glibc-tx
} | sort -u > "$L"
tar -C "$T" --numeric-owner -czf "$W/glibc-tx-update.tar.gz" -T "$L" || die "packing failed"
echo "files: $(wc -l < "$L"), archive: $(du -h "$W/glibc-tx-update.tar.gz" | cut -f1), md5 $(md5sum < "$W/glibc-tx-update.tar.gz" | cut -d' ' -f1)"
say "done in $(( ($(date +%s) - START) / 60 )) minutes"
