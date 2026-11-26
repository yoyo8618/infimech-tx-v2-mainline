#!/bin/bash
# PC test (after part C2): Klipper + Moonraker together in the emulator,
# with a full update check. PC only; repeatable; changes nothing.
#
#   sudo bash ~/fw/steps/5_debian12/pc_test.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_test.log
set -uo pipefail
W=/srv/tx
T=$W/deb12
G=/home/gem
K=$G/klipper-new
PIDS=""

ts() { date '+%H:%M:%S'; }
say() { echo; echo "$(ts) ===== $*"; }
die() { echo "$(ts) ERROR: $*"; exit 1; }
in_t() { chroot "$T" "$@"; }
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done; sleep 2
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    rm -rf "$T/tmp/ktest" "$T/tmp/mtest" "$T/tmp/printer" "$T$G/printer_data/comms/klippy.sock"
    [ -f "$W/resolv.conf.printer" ] && cp -a "$W/resolv.conf.printer" "$T/etc/resolv.conf"
    for m in dev/pts dev sys proc; do umount "$T/$m" 2>/dev/null; done
}

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -x "$T/usr/local/bin/supervisorctl" ] || die "run part C first"
grep -q " $T/" /proc/mounts && die "something is still mounted in $T"
mount -t proc proc "$T/proc" && mount --bind /sys "$T/sys" && mount --bind /dev "$T/dev" \
    && mount --bind /dev/pts "$T/dev/pts" || { cleanup; die "mounting failed"; }
trap cleanup EXIT
cp -L /etc/resolv.conf "$T/etc/resolv.conf"

say "test: Klipper + Moonraker, with a full update check"
rm -rf "$T/tmp/ktest" "$T/tmp/mtest"
cp -a "$T$G/printer_data/config_new" "$T/tmp/ktest"
sed -i 's/^manage_thresholds: .*/manage_thresholds: off/' "$T/tmp/ktest/infimech.cfg"
mkdir -p "$T/tmp/mtest/logs" "$T/tmp/mtest/gcodes" "$T/tmp/mtest/comms"
cp -a "$T$G/printer_data/config_new" "$T/tmp/mtest/config"
cp -a "$T$G/printer_data/database" "$T/tmp/mtest/database"
cp -a "$T$G/printer_data/moonraker.asvc" "$T/tmp/mtest/" 2>/dev/null
chroot "$T" sh -c "cd $K && exec $G/klippy-env/bin/python klippy/klippy.py /tmp/ktest/printer.cfg -I /tmp/printer -a $G/printer_data/comms/klippy.sock -l /tmp/ktest/klippy.log" > "$W/ktest.out" 2>&1 &
PIDS="$!"
chroot "$T" sh -c "cd $G/moonraker && exec $G/moonraker-env/bin/python moonraker/moonraker.py -d /tmp/mtest" > "$W/mtest.out" 2>&1 &
PIDS="$PIDS $!"
python3 - <<'PYEOF'
import json, time, urllib.request
B = "http://127.0.0.1:7125"
def call(p, method="GET", timeout=60):
    try:
        req = urllib.request.Request(B + p, method=method)
        return json.load(urllib.request.urlopen(req, timeout=timeout))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read()[:300]!r}"}
    except Exception as e:
        return {"error": str(e)}
def res(p, **kw):
    r = call(p, **kw)
    return r.get("result", r)
t0 = time.time()
while time.time() - t0 < 240:
    i = res("/server/info")
    if isinstance(i, dict) and i.get("klippy_connected"):
        break
    time.sleep(3)
print(f"connected after {time.time() - t0:.0f} s; klippy state: {i.get('klippy_state')}")
def wait_idle(limit):
    t = time.time()
    while time.time() - t < limit:
        s = res("/machine/update/status")
        if isinstance(s, dict) and not s.get("busy", False) and "error" not in s:
            return s
        time.sleep(5)
    return res("/machine/update/status")
# Moonraker answers "busy" until its own first check after start is done
t = time.time(); r = {}
while time.time() - t < 900:
    r = call("/machine/update/refresh", method="POST", timeout=900)
    if "result" in r or "busy" not in str(r.get("error", "")):
        break
    time.sleep(10)
print(f"full update check: {'ok' if 'result' in r else r.get('error', '')[:200]} (after {time.time() - t:.0f} s)")
s = wait_idle(300)
print("busy:", s.get("busy"), " GitHub requests left:", s.get("github_requests_remaining", s.get("github_rate_limit")))
for name, v in (s.get("version_info") or {}).items():
    if name == "system":
        print(f"  system: {v.get('package_count')} Debian packages can be updated")
        continue
    keys = ["version", "remote_version", "rollback_version", "channel", "is_valid", "is_dirty",
            "corrupt", "detached", "warnings", "anomalies", "commits_behind_count"]
    print(f"  {name}: " + ", ".join(f"{k}={v.get(k)}" for k in keys if k in v))
    if not v.get("is_valid", True) or not v:
        print(f"    full entry: {json.dumps(v)[:800]}")
sv = res("/machine/system_info").get("system_info", {})
print("services:", {k: v.get("active_state") for k, v in (sv.get("service_state") or {}).items()})
PYEOF
echo "--- moonraker.log: update manager lines"
grep -i -E "update_manager|git_deploy|app_deploy|web_deploy|klipper:|timelapse" "$T/tmp/mtest/logs/moonraker.log" 2>/dev/null \
    | grep -v -E "Downloading|Unpacking" | cut -c1-220 | tail -n 30
say "test done"
