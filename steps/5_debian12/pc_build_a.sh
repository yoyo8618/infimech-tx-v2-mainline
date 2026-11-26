#!/bin/bash
# PC build, part A: copy the printer snapshot (/srv/tx/deb11) to
# /srv/tx/deb12, remove the packages the printer doesn't need, and upgrade
# that copy from Debian 11 to Debian 12. Runs on the PC only (WSL, ARM
# emulator); the printer is not contacted. deb11 and the snapshot file stay
# untouched, so this can be repeated with REDO=1.
#
#   sudo bash ~/fw/steps/5_debian12/pc_build_a.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_build_a.log
#   (again from scratch: sudo REDO=1 bash ~/fw/steps/5_debian12/pc_build_a.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_build_a.log)
#
# Takes roughly 30-90 minutes (everything runs through the ARM emulator).
set -uo pipefail
W=/srv/tx
SRC=$W/deb11
T=$W/deb12
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
APT="apt-get -y -o APT::Get::force-yes=false -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# not needed on the printer: AVR tools, the STM32 compiler (firmware is
# built on the PC from now on), Python 2, Debian 8 leftovers, cmake
DROP="gcc-avr avr-libc binutils-avr avrdude gcc-arm-none-eabi libnewlib-arm-none-eabi libnewlib-dev
      libstdc++-arm-none-eabi-newlib binutils-arm-none-eabi libllvm3.5 libicu52 perl-modules
      python2.7 python2.7-minimal libpython2.7 libpython2.7-stdlib libpython2.7-minimal python-openssl
      libpython3.7-dev cmake cmake-data"
# must stay installed
KEEP="nginx git python3 python3-dev python3-venv python3-pip sudo tmux build-essential gcc make ffmpeg curl wget
      stm32flash dfu-util libsodium-dev libopenjp2-7 libjpeg-dev zlib1g-dev liblmdb-dev libffi-dev
      libssl-dev packagekit iproute2 xz-utils"

ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; exit 1; }
mounted() { grep -q " $T/" /proc/mounts; }
umount_all() {
    [ -f "$W/resolv.conf.printer" ] && [ -d "$T/etc" ] && cp -a "$W/resolv.conf.printer" "$T/etc/resolv.conf"
    for m in dev/pts dev sys proc; do umount "$T/$m" 2>/dev/null; done
}
in_t() { chroot "$T" "$@"; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -x "$SRC/usr/bin/dpkg" ] || die "$SRC not found - unpack the snapshot first"
ls /proc/sys/fs/binfmt_misc/ | grep -q qemu-arm || die "ARM emulator not active (qemu-arm missing)"

if [ -e "$T" ]; then
    [ "${REDO:-}" = 1 ] || die "$T exists. To start over: sudo REDO=1 bash ~/fw/steps/5_debian12/pc_build_a.sh ..."
    for m in dev/pts dev sys proc; do umount "$T/$m" 2>/dev/null; done
    rm -f "$W/resolv.conf.printer"
    mounted && { grep " $T/" /proc/mounts; die "still mounted inside $T - nothing removed"; }
    say "removing the old $T"
    rm -rf "$T"
fi

START=$(date +%s)
say "copying deb11 -> deb12"
cp -a "$SRC" "$T" || die "copy failed"
mkdir -p "$T/tmp" && chmod 1777 "$T/tmp"
for m in proc sys dev dev/pts; do mkdir -p "$T/$m"; done
mount -t proc proc "$T/proc" && mount --bind /sys "$T/sys" && mount --bind /dev "$T/dev" \
    && mount --bind /dev/pts "$T/dev/pts" || { umount_all; die "mounting failed"; }
trap umount_all EXIT

say "apt settings"
# keep 'assume yes', drop 'force-yes' (it lets apt remove essential packages)
printf 'APT::Get::Assume-Yes "true";\n' > "$T/etc/apt/apt.conf.d/90forceyes"
# no manuals, docs or translations on the printer (saves ~200 MB)
cat > "$T/etc/dpkg/dpkg.cfg.d/01-printer-nodoc" <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/man/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/locale/*
path-include=/usr/share/locale/locale.alias
EOF
in_t sh -c 'echo "man-db man-db/auto-update boolean false" | debconf-set-selections'
# use the PC's DNS while building; the printer's resolv.conf goes back at the end
cp -a "$T/etc/resolv.conf" "$W/resolv.conf.printer"
cp -L /etc/resolv.conf "$T/etc/resolv.conf"
in_t getent hosts deb.debian.org > /dev/null || die "no DNS inside the copy"

say "Debian 11: update and remove unneeded packages"
in_t $APT update || die "apt update failed"
have=""
for p in $DROP; do in_t dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" && have="$have $p"; done
echo "removing:$have"
in_t $APT -s purge $have > "$W/purge_sim.txt" 2>&1
bad=""
for k in $KEEP; do grep -q -E "^(Remv|Purg) $k " "$W/purge_sim.txt" && bad="$bad $k"; done
[ -z "$bad" ] || die "removing those would also remove:$bad - stopped (see $W/purge_sim.txt)"
in_t $APT purge $have || die "purge failed"
in_t $APT autoremove --purge || die "autoremove failed"
echo "size of usr now: $(du -sh $T/usr | cut -f1)"

say "switching to Debian 12 (bookworm)"
cp "$T/etc/apt/sources.list" "$T/etc/apt/sources.list.bullseye"
cat > "$T/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://deb.debian.org/debian-security bookworm-security main
EOF
in_t $APT update || die "apt update (bookworm) failed"
say "upgrade, step 1 (no new packages)"
in_t $APT upgrade --without-new-pkgs || die "upgrade step 1 failed"
say "upgrade, step 2 (full)"
in_t $APT full-upgrade || die "full-upgrade failed"
in_t $APT autoremove --purge
in_t apt-get clean

say "checks"
echo "debian: $(cat $T/etc/debian_version)"
in_t python3 --version
in_t dpkg --audit && echo "dpkg --audit: ok"
in_t apt-get check > /dev/null && echo "apt-get check: ok"
missing=""
for k in $KEEP; do in_t dpkg-query -W -f='${Status}' "$k" 2>/dev/null | grep -q "ok installed" || missing="$missing $k"; done
echo "packages that must stay, missing:${missing:- none}"
echo "--- packages not from Debian 12 (obsolete):"
in_t apt list '?obsolete' 2>/dev/null | grep -v '^Listing' | cut -d/ -f1 | tr '\n' ' '; echo
echo "--- programs and the libraries they need (missing ones shown):"
for b in /usr/local/bin/klipper_mcu /home/gem/klipper-new/out-host/klipper.elf /usr/sbin/nginx \
         /usr/bin/ffmpeg $(cd "$T" && for f in home/gem/helixscreen/*; do [ -f "$f" ] && [ -x "$f" ] && echo "/$f"; done); do
    [ -f "$T$b" ] || continue
    head -c 4 "$T$b" | grep -q ELF || continue
    m=$(in_t ldd "$b" 2>&1 | grep -E 'not found|not a dynamic')
    echo "$b: ${m:-ok}"
done
in_t nginx -t 2>&1 | tail -n 2
echo "--- sizes"
du -sh "$T/usr" "$T/var" "$T/home" "$T" 2>/dev/null
say "part A done in $(( ($(date +%s) - START) / 60 )) minutes (the copy is in $T)"
