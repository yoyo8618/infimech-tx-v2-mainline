#!/bin/bash
# PC build, part B (after part A): Python environments for Debian 12,
# a current Moonraker, and offline tests - all in /srv/tx/deb12 on the PC.
# The printer is not contacted. Repeatable: it rebuilds what it makes.
#
#   sudo bash ~/fw/steps/5_debian12/pc_build_b.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_build_b.log
#
# Takes roughly 15-45 minutes (pip may compile some packages through the
# ARM emulator).
set -uo pipefail
W=/srv/tx
T=$W/deb12
OLD=$W/deb11
G=/home/gem
export DEBIAN_FRONTEND=noninteractive LC_ALL=C LANG=C
APT="apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
KEEP="nginx git python3 python3-dev python3-venv python3-pip sudo tmux build-essential gcc make ffmpeg curl wget
      stm32flash dfu-util libsodium-dev libopenjp2-7 libjpeg-dev zlib1g-dev libffi-dev
      libssl-dev packagekit iproute2 xz-utils procps psmisc"
MOON_PID=""

ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; exit 1; }
in_t() { chroot "$T" "$@"; }
owner() { stat -c '%u:%g' "$1"; }
umount_all() {
    [ -n "$MOON_PID" ] && kill "$MOON_PID" 2>/dev/null && sleep 2
    [ -f "$W/resolv.conf.printer" ] && cp -a "$W/resolv.conf.printer" "$T/etc/resolv.conf"
    for m in dev/pts dev sys proc; do umount "$T/$m" 2>/dev/null; done
}

[ "$(id -u)" = 0 ] || die "run with sudo"
grep -q '^12' "$T/etc/debian_version" 2>/dev/null || die "$T is not the Debian 12 copy - run part A first"
grep -q " $T/" /proc/mounts && die "something is still mounted in $T (another build running?)"
START=$(date +%s)
mount -t proc proc "$T/proc" && mount --bind /sys "$T/sys" && mount --bind /dev "$T/dev" \
    && mount --bind /dev/pts "$T/dev/pts" || { umount_all; die "mounting failed"; }
trap umount_all EXIT
[ -f "$W/resolv.conf.printer" ] || cp -a "$T/etc/resolv.conf" "$W/resolv.conf.printer"
cp -L /etc/resolv.conf "$T/etc/resolv.conf"
GEM=$(owner "$T$G")
echo "owner of /home/gem: $GEM"

say "system fix-ups"
in_t $APT update > /dev/null || die "apt update failed"
# procps/psmisc (ps, pkill, killall) were dropped as unused in part A; Moonraker
# wants wireless-tools; everything else Moonraker needs is already there
in_t $APT install procps psmisc wireless-tools python3-virtualenv || die "install failed"
in_t apt-mark manual procps psmisc wireless-tools > /dev/null
# Debian 10/11 leftovers that Debian 12 replaced (old gcc versions etc.)
obs=$(in_t apt list '?obsolete' 2>/dev/null | grep -v '^Listing' | cut -d/ -f1 | tr '\n' ' ')
if [ -n "$obs" ]; then
    in_t $APT -s purge $obs > "$W/obsolete_sim.txt" 2>&1
    bad=""
    for k in $KEEP; do grep -q -E "^(Remv|Purg) $k " "$W/obsolete_sim.txt" && bad="$bad $k"; done
    if [ -z "$bad" ]; then in_t $APT purge $obs && in_t $APT autoremove --purge
    else echo "kept the old packages ($obs): removing them would also remove$bad"; fi
fi
in_t apt-get clean
# git: Moonraker runs as root and the repos belong to gem
in_t git config --system --replace-all safe.directory '*'
# ready-made ARM wheels for pip (here and for later updates on the printer)
printf '[global]\nextra-index-url=https://www.piwheels.org/simple\n' > "$T/etc/pip.conf"
# time zone as on the printer
if [ -f "$OLD/etc/timezone" ] && ! cmp -s "$OLD/etc/timezone" "$T/etc/timezone"; then
    cp -a "$OLD/etc/timezone" "$T/etc/timezone"; cp -a "$OLD/etc/localtime" "$T/etc/localtime"
    echo "time zone restored: $(cat $T/etc/timezone)"
fi
echo "time zone: $(cat $T/etc/timezone 2>/dev/null) / $(readlink $T/etc/localtime)"
# gcodes were left out of the snapshot; the folder must exist (filled on the printer)
[ -d "$T$G/printer_data/gcodes" ] || { mkdir "$T$G/printer_data/gcodes"; chown "$(owner "$T$G/printer_data")" "$T$G/printer_data/gcodes"; }

say "klippy-env (Python 3.11; numpy from Debian)"
REQ=$G/klipper-new/scripts/klippy-requirements.txt
rm -rf "$T$G/klippy-env"
in_t python3 -m venv --system-site-packages $G/klippy-env || die "venv failed"
in_t $G/klippy-env/bin/pip install --no-cache-dir --progress-bar off -r $REQ || die "klippy-env packages failed"
in_t $G/klippy-env/bin/python -c "import greenlet, cffi, jinja2, serial, can, numpy; print('klippy-env ok, numpy', numpy.__version__)" || die "klippy-env import test failed"
chown -R "$GEM" "$T$G/klippy-env"

say "Moonraker (current, fresh copy)"
if [ -d "$T$G/moonraker.vendor" ]; then rm -rf "$T$G/moonraker"
else mv "$T$G/moonraker" "$T$G/moonraker.vendor"; fi
git clone -q https://github.com/Arksine/moonraker.git "$T$G/moonraker" || die "git clone failed"
git -c safe.directory='*' -C "$T$G/moonraker" log -1 --format='moonraker: %h %ad %s' --date=short
TL=$G/moonraker-timelapse/component/timelapse.py
if [ -f "$T$TL" ]; then
    ln -sf "$TL" "$T$G/moonraker/moonraker/components/timelapse.py"
    echo "moonraker/components/timelapse.py" >> "$T$G/moonraker/.git/info/exclude"
    echo "timelapse component linked"
else
    echo "WARNING: $TL not found - timelapse component not linked"
fi
chown -R "$GEM" "$T$G/moonraker"
rm -rf "$T$G/moonraker-env"
in_t python3 -m venv $G/moonraker-env || die "venv failed"
in_t $G/moonraker-env/bin/pip install --no-cache-dir --progress-bar off -r $G/moonraker/scripts/moonraker-requirements.txt lmdb \
    || die "moonraker-env packages failed"
chown -R "$GEM" "$T$G/moonraker-env"

say "precompiling Python files and Klipper's C helper"
for d in klipper-new/klippy klipper/klippy moonraker/moonraker; do
    in_t $G/klippy-env/bin/python -m compileall -q $G/$d > /dev/null 2>&1; echo "compiled: $d"
done
for k in klipper-new klipper; do
    in_t sh -c "cd $G/$k/klippy && $G/klippy-env/bin/python -c 'import chelper; chelper.get_ffi(); print(\"$k chelper ok\")'" 2>&1 | tail -n 2
done

say "test 1: new Klipper (v0.14) offline test print"
in_t sh -c '
H=/home/gem; T=$H/printer_data/config_new.check-tmp
rm -rf $T; cp -a $H/printer_data/config_new $T
sed -i "s/^manage_thresholds: .*/manage_thresholds: off/" $T/infimech.cfg
cd /tmp
$H/klippy-env/bin/python $H/klipper-new/klippy/klippy.py $T/printer.cfg \
    -i $H/infimech/clean/check_print_start.gcode -o /tmp/check.out \
    -d $H/infimech/klipper-v0.14.0-stm32f072-mainboard.dict \
    -d rpi=$H/klipper-new/out-host/klipper.dict -l /tmp/check.log > /dev/null 2>&1
rc=$?
echo "exit code $rc, unknown commands $(grep -c "Unknown command" /tmp/check.log), adaptive mesh $(grep -c "^Adapted probe count: (3,3)" /tmp/check.log), finished $(grep -c "^Exiting (print time" /tmp/check.log)"
[ $rc = 0 ] || grep -E "^Config error|Error|Unknown command|!!" /tmp/check.log \
    | grep -vE "device-tree|dmi/id|FileNotFoundError|git config|action_raise_error" | tail -n 15
rm -rf $T /tmp/check.out /tmp/check.out-rpi
'

say "test 2: stock Klipper (fallback)"
echo "--- kp.sh.stock:"; grep -v '^\s*#' "$T$G/kp.sh.stock" | grep -v '^\s*$'
dicts=$(cd "$T" && find home/gem/klipper home/gem/infimech home/gem/printer_data -name '*.dict' 2>/dev/null | grep -v -E 'v0.14|klipper-new' | head -n 5)
echo "stock dictionaries found: ${dicts:-none}"
in_t sh -c "cd /tmp && $G/klippy-env/bin/python $G/klipper/klippy/klippy.py --help > /dev/null 2>&1" \
    && echo "stock Klipper starts under Python 3.11" || echo "WARNING: stock Klipper does not start under Python 3.11"
in_t sh -c "cd /tmp && $G/klippy-env/bin/python $G/klipper/klippy/klippy.py $G/printer_data/config_stock/printer.cfg -i /dev/null -o /tmp/stock.out -l /tmp/stock.log > /dev/null 2>&1"
echo "stock config load (no dictionaries, so it may stop at the MCU step):"
grep -E "^Config error|Error|Traceback|dictionary|Exiting" "$T/tmp/stock.log" 2>/dev/null | head -n 8
rm -f "$T/tmp/stock.out"* "$T/tmp/stock.log"

say "test 3: Moonraker with a copy of the printer's data (database migration)"
MT=/tmp/mtest
rm -rf "$T$MT"; mkdir -p "$T$MT/logs" "$T$MT/comms" "$T$MT/gcodes"
cp -a "$T$G/printer_data/config_new" "$T$MT/config"
cp -a "$T$G/printer_data/database" "$T$MT/database"
[ -f "$T$G/printer_data/.moonraker.uuid" ] && cp -a "$T$G/printer_data/.moonraker.uuid" "$T$MT/"
echo "old database files: $(cd "$T$MT/database" && echo *)"
chroot "$T" sh -c "cd $G/moonraker && exec $G/moonraker-env/bin/python moonraker/moonraker.py -d $MT" > "$W/mtest.out" 2>&1 &
MOON_PID=$!
ok=""
for i in $(seq 1 90); do
    curl -s -m 2 http://127.0.0.1:7125/server/info > "$W/m_info.json" 2>/dev/null && ok=1 && break
    kill -0 "$MOON_PID" 2>/dev/null || break
    sleep 2
done
if [ -n "$ok" ]; then
    python3 - "$W" <<'PYEOF'
import json, sys, urllib.request
w = sys.argv[1]
def get(p):
    try:
        return json.load(urllib.request.urlopen("http://127.0.0.1:7125" + p, timeout=10))["result"]
    except Exception as e:
        return {"error": str(e)}
i = get("/server/info")
print("moonraker version:", i.get("moonraker_version"))
print("klippy state:", i.get("klippy_state"), "(no Klipper here - expected)")
print("components:", " ".join(sorted(i.get("components", []))))
print("failed components:", i.get("failed_components"))
for wmsg in i.get("warnings", []):
    print("warning:", wmsg)
print("database namespaces:", get("/server/database/list").get("namespaces"))
t = get("/server/history/totals").get("job_totals", {})
print("history: jobs", t.get("total_jobs"), " print time h", round((t.get("total_print_time") or 0) / 3600, 1),
      " filament m", round((t.get("total_filament_used") or 0) / 1000, 1))
print("file roots:", [(r.get("name"), r.get("permissions")) for r in get("/server/files/roots") if isinstance(r, dict)])
PYEOF
else
    echo "Moonraker did not answer"; tail -n 30 "$W/mtest.out"
fi
kill "$MOON_PID" 2>/dev/null; sleep 3; kill -9 "$MOON_PID" 2>/dev/null; MOON_PID=""
echo "--- moonraker.log (migration, warnings, errors):"
grep -i -E "lmdb|migrat|convert|warning|error|exception" "$T$MT/logs/moonraker.log" 2>/dev/null | cut -c1-220 | head -n 25
echo "new database files: $(cd "$T$MT/database" 2>/dev/null && echo *)"
rm -rf "$T$MT"

say "test 4: HelixScreen libraries"
find "$T$G/helixscreen" -maxdepth 3 -type f -perm -u+x 2>/dev/null | while read -r f; do
    head -c 4 "$f" | grep -q ELF || continue
    b=${f#$T}; m=$(in_t ldd "$b" 2>&1 | grep -E 'not found|not a dynamic')
    echo "$b: ${m:-ok}"
done

say "sizes"
du -sh "$T/usr" "$T/home" "$T$G/klippy-env" "$T$G/moonraker-env" "$T$G/moonraker.vendor" 2>/dev/null
echo "total: $(du -sh "$T" | cut -f1)"
say "part B done in $(( ($(date +%s) - START) / 60 )) minutes"
