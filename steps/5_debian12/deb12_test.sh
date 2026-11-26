#!/bin/sh
# Printer side: tests the received Debian 12 system (/server/deb12) on the
# printer's own kernel, next to the running system, with the printer idle.
# Reads the live config and database (copies), changes nothing in /server/tmp.
# A test Moonraker runs on port 7126 for a minute.
# Version 3: Debian 12 programs run directly (needs the rebuilt glibc,
# "+tx" version, because the vendor kernel's syscalls 397/398 are not
# statx/rseq). /usr/local/sbin/nostatx is used only if it works.
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_test.sh > ~/fw/steps/5_debian12/deb12_test.txt 2>&1
R=/server
L=$R/tmp
N=$R/deb12
H=/home/gem
MPID=""
NS=$N/usr/local/sbin/nostatx
ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "ERROR: $*"; exit 1; }
WR=""
inn() { $WR chroot "$N" "$@" < /dev/null; }   # never read the script stream
cleanup() {
    [ -n "$MPID" ] && kill "$MPID" 2>/dev/null && sleep 3 && kill -9 "$MPID" 2>/dev/null
    rm -rf "$N/tmp/mtest" "$N/tmp/cfgcheck" "$N/tmp/check".*
    for m in sys proc dev/pts dev; do umount "$N/$m" 2>/dev/null; done
}

[ "$(id -u)" = 0 ] || die "run as root"
grep -q '^12' "$N/etc/debian_version" 2>/dev/null || die "no Debian 12 system in $N"
grep -q " $N/" /proc/mounts && die "something is mounted in $N already"
state=$(chroot "$L" python3 -c '
import json, urllib.request
try:
    r = urllib.request.urlopen("http://127.0.0.1:7125/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")' < /dev/null)
echo "print state: $state"
case "$state" in printing|paused) die "the printer is $state - run this when it is idle" ;; esac
say "0. C library"
echo "glibc in the copy: $(grep -A12 '^Package: libc6$' "$N/var/lib/dpkg/status" | grep '^Version:')"
[ -x "$NS" ] && "$NS" --check > /dev/null 2>&1 && WR=$NS && echo "using nostatx"
for m in dev dev/pts proc sys; do mount --bind "/$m" "$N/$m" || { cleanup; die "mount $m failed"; }; done
trap cleanup EXIT

say "1. basics on the printer's kernel"
inn sh -c 'echo "kernel $(uname -r), debian $(cat /etc/debian_version), $(python3 --version)"'
inn sh -c 'ls -l /usr/bin/python3 > /dev/null && echo "ls -l: ok"; ls -ld /home/gem > /dev/null && echo "ls -ld: ok"'
inn sh -c 'echo "ps: $(ps -e | wc -l) processes"; date; df -h /home | tail -n 1'
inn sh -c 'dpkg --audit && echo "dpkg --audit: ok"'
inn $H/moonraker-env/bin/python -c "import tornado, PIL, lmdb, dbus_fast, zeroconf, libnacl, apprise; print('moonraker-env imports: ok')"
inn $H/klippy-env/bin/python -c "import greenlet, cffi, jinja2, serial, can, numpy; print('klippy-env imports: ok')"
for k in klipper-new klipper; do
    inn sh -c "cd $H/$k/klippy && $H/klippy-env/bin/python -c 'import chelper; chelper.get_ffi(); print(\"$k C helper: ok\")'" 2>&1 | tail -n 1
done

say "2. git (refreshes the file index after the copy)"
for r in klipper-new moonraker moonraker-timelapse; do
    c=$(inn git -C $H/$r status --porcelain | wc -l)
    echo "$r: $c changes, $(inn git -C $H/$r describe --always --tags --long --dirty), branch $(inn git -C $H/$r rev-parse --abbrev-ref HEAD)"
done

say "3. programs and their libraries"
for b in $H/helixscreen/bin/helix-screen-fbdev $H/klipper-host/klipper.elf /usr/local/bin/klipper_mcu /usr/sbin/nginx /usr/bin/ffmpeg; do
    out=$(inn ldd "$b" 2>&1); rc=$?
    m=$(echo "$out" | grep -E 'not found|not a dynamic|error while loading')
    [ $rc = 0 ] && [ -z "$m" ] && echo "$b: ok" || echo "$b: PROBLEM (ldd exit $rc) $(echo "$m" | head -n 3)"
done
inn nginx -t 2>&1 | tail -n 1
echo "supervisorctl (sees the running system's processes): $(inn /usr/local/bin/supervisorctl status | tr -s ' ' | tr '\n' ';')"

say "4. Klipper v0.14 offline test print with your current config"
rm -rf "$N/tmp/cfgcheck"; cp -a "$L$H/printer_data/config_new" "$N/tmp/cfgcheck"
sed -i 's/^manage_thresholds: .*/manage_thresholds: off/' "$N/tmp/cfgcheck/infimech.cfg"
t0=$(date +%s)
inn sh -c "cd /tmp && $H/klippy-env/bin/python $H/klipper-new/klippy/klippy.py /tmp/cfgcheck/printer.cfg \
    -i $H/infimech/clean/check_print_start.gcode -o /tmp/check.out \
    -d $H/infimech/klipper-v0.14.0-stm32f072-mainboard.dict \
    -d rpi=$H/klipper-host/klipper.dict -l /tmp/check.log > /dev/null 2>&1"
rc=$?
lg=$N/tmp/check.log
echo "exit code $rc, unknown commands $(grep -c 'Unknown command' $lg), adaptive mesh $(grep -c '^Adapted probe count: (3,3)' $lg), finished $(grep -c '^Exiting (print time' $lg) ($(( $(date +%s) - t0 )) s)"
[ $rc = 0 ] || grep -E "^Config error|Error|Unknown command|!!" $lg | grep -vE "device-tree|dmi/id|FileNotFoundError|git config|action_raise_error" | tail -n 15

say "5. Moonraker (new) on port 7126 with copies of your config and database"
MT=$N/tmp/mtest
rm -rf "$MT"; mkdir -p "$MT/logs" "$MT/gcodes" "$MT/comms"
cp -a "$L$H/printer_data/config_new" "$MT/config"
cp -a "$L$H/printer_data/database" "$MT/database"
cp -a "$N$H/printer_data/moonraker.asvc" "$MT/"
inn bash $H/infimech/moonraker_patch.sh /tmp/mtest/config > /dev/null
sed -i -e '/^\[server\]/,/^\[/ s/^port:.*/port: 7126/' \
       -e '/^\[server\]/,/^\[/ s#^klippy_uds_address:.*#klippy_uds_address: /tmp/mtest/comms/klippy.sock#' \
       -e '/^\[include infimech_moonraker.conf\]/d' "$MT/config/moonraker.conf"
t0=$(date +%s)
$WR chroot "$N" sh -c "cd $H/moonraker && exec $H/moonraker-env/bin/python moonraker/moonraker.py -d /tmp/mtest" > /dev/null 2>&1 < /dev/null &
MPID=$!
$WR chroot "$N" python3 - <<'PYEOF'
import json, time, urllib.request
B = "http://127.0.0.1:7126"
def res(p):
    try:
        return json.load(urllib.request.urlopen(B + p, timeout=20))["result"]
    except Exception as e:
        return {"error": str(e)}
t0 = time.time()
i = {}
while time.time() - t0 < 240:
    i = res("/server/info")
    if "error" not in i:
        break
    time.sleep(3)
print(f"answered after {time.time() - t0:.0f} s")
print("moonraker:", i.get("moonraker_version"), " failed components:", i.get("failed_components"))
for w in i.get("warnings", []):
    print("warning:", w)
t = res("/server/history/totals").get("job_totals", {})
print("history: jobs", t.get("total_jobs"), " print time h", round((t.get("total_print_time") or 0) / 3600, 1))
print("database:", res("/server/database/list").get("namespaces"))
print("file roots:", [(r.get("name"), r.get("permissions")) for r in res("/server/files/roots") if isinstance(r, dict)])
s = res("/machine/system_info").get("system_info", {})
print("services:", {k: v.get("active_state") for k, v in (s.get("service_state") or {}).items()})
PYEOF
kill "$MPID" 2>/dev/null; sleep 3; kill -9 "$MPID" 2>/dev/null; MPID=""
echo "($(( $(date +%s) - t0 )) s)"
grep -i -E "error|exception|traceback" "$MT/logs/moonraker.log" 2>/dev/null | grep -v -i "klippy\|klipper" | cut -c1-200 | head -n 8
rm -rf "$MT"

say "space"
df -h "$R" | tail -n 1
say "done (nothing in /server/tmp was changed)"
