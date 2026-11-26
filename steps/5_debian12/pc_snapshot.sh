#!/bin/bash
# Snapshots of the printer's Debian systems, saved on the PC.
# Run it in the Ubuntu (WSL) window, with the printer idle:
#   bash ~/fw/pc_snapshot.sh <PRINTER_IP>            # both
#   bash ~/fw/pc_snapshot.sh <PRINTER_IP> deb11      # only the old Debian 11
#   bash ~/fw/pc_snapshot.sh <PRINTER_IP> deb12      # only the running Debian 12
# It asks for the printer's root password once (one shared ssh connection).
#
# deb11: /server/tmp_deb11, the old Debian 11 (not running). Complete.
# deb12: /server/tmp, the running Debian 12. Complete apart from G-code
#        files, timelapse files and caches. Moonraker is stopped while it is
#        copied (Fluidd and the screen lose the connection for a few
#        minutes) and started again; Klipper keeps running.
# The files go to ~/fw/snapshots (OUT=... to change it):
#   deb11-<date>.tar.gz / deb12-<date>.tar.gz, each with a .sha256 file.
# Each snapshot is checked: gzip test, number of entries against the
# printer, Debian version and key files inside. After a good deb11 snapshot
# the printer gets the marker /server/tmp_deb11/.snapshot_ok, which
# deb11_remove.sh asks for. Nothing on the printer is changed otherwise.
set -u -o pipefail
IP=${1:?usage: pc_snapshot.sh <PRINTER_IP> [both|deb11|deb12]}
WHAT=${2:-both}
OUT=${OUT:-$HOME/fw/snapshots}
RS=${RS:-/server}                      # the printer's /server (changed only for tests)
D=$(date +%Y%m%d-%H%M)
EXCL12="/home/gem/printer_data/gcodes /home/gem/printer_data/timelapse /home/gem/.cache /root/.cache"
die() { echo "ERROR: $*"; exit 1; }
say() { echo; echo "$(date +%H:%M:%S) === $*"; }
case "$WHAT" in both|deb11|deb12) ;; *) die "second argument: both, deb11 or deb12" ;; esac
mkdir -p "$HOME/.ssh" "$OUT" || die "cannot create $OUT"
CP="$HOME/.ssh/tx-snap-%r@%h-%p"
SSH=(ssh -o ControlMaster=auto -o "ControlPath=$CP" -o ControlPersist=20m
     -o ServerAliveInterval=30 "root@$IP")
r() { "${SSH[@]}" "$@"; }
trap 'ssh -o "ControlPath=$CP" -O exit "root@$IP" 2>/dev/null' EXIT

# find options that select what tar packs (sockets are skipped by tar)
prune12=""
for p in $EXCL12; do prune12="$prune12 -path $p -o"; done
prune12="\\( ${prune12% -o} \\) -prune -o"
tarx12=""
for p in $EXCL12; do tarx12="$tarx12 --exclude=.$p"; done

say "1. checks on the printer (read only)"
info=$(r sh -s <<EOF
R=$RS
for d in tmp tmp_deb11; do
    echo "ver_\$d=\$(cat \$R/\$d/etc/debian_version 2>/dev/null)"
done
echo "mounts11=\$(grep -c " \$R/tmp_deb11[/ ]" /proc/mounts)"
n=0; for p in /proc/[0-9]*; do [ "\$(readlink \$p/root 2>/dev/null)" = "\$R/tmp_deb11" ] && n=\$((n+1)); done
echo "procs11=\$n"
echo "marker11=\$(cat \$R/tmp_deb11/.snapshot_ok 2>/dev/null | head -n 1)"
if [ "$WHAT" != deb12 ] && [ -d \$R/tmp_deb11 ]; then
    echo "kb11=\$(chroot \$R/tmp_deb11 du -sxk / 2>/dev/null | cut -f1)"
    echo "n11=\$(chroot \$R/tmp_deb11 find / -xdev ! -type s 2>/dev/null | wc -l)"
fi
if [ "$WHAT" != deb11 ]; then
    echo "kb12=\$(chroot \$R/tmp du -sxk / $(for p in $EXCL12; do printf ' --exclude=%s' "$p"; done) 2>/dev/null | cut -f1)"
    echo "state=\$(chroot \$R/tmp python3 -c '
import json, urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")' < /dev/null 2>/dev/null)"
fi
echo "freekb=\$(df -k \$R | tail -n 1 | awk '{print \$4}')"
EOF
) || die "ssh to the printer failed"
echo "$info"
val() { echo "$info" | sed -n "s/^$1=//p" | head -n 1; }

need_kb=0
if [ "$WHAT" != deb12 ]; then
    case "$(val ver_tmp_deb11)" in 11*) ;; *) die "/server/tmp_deb11 is not a Debian 11 system" ;; esac
    [ "$(val mounts11)" = 0 ] || die "something is mounted inside /server/tmp_deb11"
    [ "$(val procs11)" = 0 ] || die "programs are running inside /server/tmp_deb11"
    need_kb=$((need_kb + $(val kb11)))
fi
if [ "$WHAT" != deb11 ]; then
    case "$(val ver_tmp)" in 12*) ;; *) die "/server/tmp is not the Debian 12 system" ;; esac
    case "$(val state)" in standby|complete|cancelled|error) ;;
        *) die "printer state is '$(val state)' - run this when the printer is idle" ;; esac
    need_kb=$((need_kb + $(val kb12)))
fi
avail=$(df -kP "$OUT" | tail -n 1 | awk '{print $4}')
echo "on the printer: $((need_kb / 1024)) MB to copy; free in $OUT: $((avail / 1024)) MB"
[ "$avail" -gt "$need_kb" ] || die "not enough free space in $OUT"

# check(name, file, expected entries, debian major, strict, key files...)
check() {
    local name=$1 f=$2 want=$3 major=$4 strict=$5; shift 5
    local list="$f.list" n ver k
    echo "checking $name ..."
    gzip -t "$f" || die "$name: gzip test failed"
    tar -tzf "$f" > "$list" || die "$name: tar cannot list it"
    n=$(wc -l < "$list")
    for k in "$@"; do
        grep -qx -- "$k" "$list" || die "$name: $k is missing in the snapshot"
    done
    rm -f "$list"
    ver=$(tar -xzOf "$f" ./etc/debian_version) || die "$name: cannot read etc/debian_version"
    case "$ver" in "$major"*) ;; *) die "$name: Debian version in the snapshot is '$ver'" ;; esac
    echo "$name: $n entries (printer: $want), Debian $ver"
    if [ "$n" != "$want" ]; then
        [ "$strict" = 1 ] && die "$name: entry count differs from the printer"
        echo "  note: the count differs a little because the system was running"
    fi
}

if [ "$WHAT" != deb12 ]; then
    say "2. Debian 11 snapshot (/server/tmp_deb11)"
    F="$OUT/deb11-$D.tar.gz"
    r "chroot $RS/tmp_deb11 tar --one-file-system --numeric-owner -cf - -C / .; echo TAR_RC=\$? >&2" \
        2> "$F.log" | gzip -1 > "$F.part" || die "copy failed (see $F.log)"
    grep -q '^TAR_RC=0$' "$F.log" || { cat "$F.log"; die "tar on the printer reported an error"; }
    mv "$F.part" "$F"
    check deb11 "$F" "$(val n11)" 11 1 ./etc/debian_version ./go.sh ./updatestm32 ./home/gem/
    (cd "$OUT" && sha256sum "$(basename "$F")" > "$(basename "$F").sha256")
    sha=$(cut -d' ' -f1 < "$F.sha256")
    r "printf '%s\n' '$(basename "$F") sha256 $sha' > $RS/tmp_deb11/.snapshot_ok" \
        || die "could not write the marker on the printer"
    echo "deb11 OK: $F ($(du -m "$F" | cut -f1) MB); marker written on the printer"
fi

if [ "$WHAT" != deb11 ]; then
    say "3. Debian 12 snapshot (/server/tmp, running; Moonraker stopped meanwhile)"
    F="$OUT/deb12-$D.tar.gz"
    n12=$(r "chroot $RS/tmp sh -c 'find / -xdev $prune12 ! -type s -print 2>/dev/null | wc -l'")
    r "L=$RS/tmp; chroot \$L /usr/local/bin/supervisorctl stop moonraker >&2
       trap 'chroot \$L /usr/local/bin/supervisorctl start moonraker >&2' EXIT HUP INT TERM PIPE
       chroot \$L tar --one-file-system --numeric-owner --warning=no-file-ignored $tarx12 -cf - -C / .
       echo TAR_RC=\$? >&2" 2> "$F.log" | gzip -1 > "$F.part" || die "copy failed (see $F.log)"
    # 1 = files changed while being read (logs of a running system): accepted
    grep -q '^TAR_RC=[01]$' "$F.log" || { cat "$F.log"; die "tar on the printer reported an error"; }
    mv "$F.part" "$F"
    check deb12 "$F" "$n12" 12 0 ./etc/debian_version ./home/gem/printer_data/config_new/printer.cfg \
        ./home/gem/printer_data/database/
    (cd "$OUT" && sha256sum "$(basename "$F")" > "$(basename "$F").sha256")
    echo "deb12 OK: $F ($(du -m "$F" | cut -f1) MB); Moonraker started again"
fi
say "DONE. Snapshots in $OUT"
ls -l "$OUT"
