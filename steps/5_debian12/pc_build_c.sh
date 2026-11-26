#!/bin/bash
# PC build, part C (after part B): get /srv/tx/deb12 ready for updates from
# Fluidd, then test Klipper + Moonraker together in the emulator.
# (Consolidated: includes the former part C2 and the later printer fixes;
#  klipper_links.sh, svc_loop.sh and supervisorctl come from ../files.)
#  - Klipper folder made "clean" for Moonraker: our add-ons move to
#    /home/gem/infimech/klippy_extras (linked back at every Klipper start),
#    the host MCU program to /home/gem/klipper-host, config.host to
#    /home/gem/infimech/firmware
#  - services kept running by small loops (run.sh), and a supervisorctl
#    stand-in, so Fluidd's restart buttons and the update manager can
#    restart Klipper, Moonraker and the host MCU program
#  - moonraker.conf: update manager for Klipper (releases only), Moonraker,
#    Fluidd, timelapse and Debian packages
#  - the STM32/AVR compilers are blocked from coming back through apt
# The printer is not contacted. Repeatable.
#
#   sudo bash ~/fw/steps/5_debian12/pc_build_c.sh 2>&1 | tee ~/fw/steps/5_debian12/pc_build_c.log
set -uo pipefail
W=/srv/tx
T=$W/deb12
FILES=$(cd "$(dirname "$(readlink -f "$0")")/../files" && pwd)   # steps/files
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
[ -x "$T$G/moonraker-env/bin/python" ] || die "run part B first"
grep -q " $T/" /proc/mounts && die "something is still mounted in $T (another build running?)"
START=$(date +%s)
mount -t proc proc "$T/proc" && mount --bind /sys "$T/sys" && mount --bind /dev "$T/dev" \
    && mount --bind /dev/pts "$T/dev/pts" || { cleanup; die "mounting failed"; }
trap cleanup EXIT
cp -L /etc/resolv.conf "$T/etc/resolv.conf"
mkdir -p "$T$G/infimech/svc" "$T$G/infimech/firmware" "$T$G/infimech/klippy_extras" "$T$G/infimech/backup"

say "1. Klipper folder: add-ons and host MCU program moved out"
cd "$T$K" || die "no $K"
for f in klippy/extras/infimech_*.py; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    mv "$f" "$T$G/infimech/klippy_extras/" && echo "moved $f"
done
for f in klippy/extras/infimech_*.py.bak-*; do [ -e "$f" ] && mv "$f" "$T$G/infimech/backup/" && echo "moved $f to infimech/backup"; done
for f in config.host config.host.old; do [ -f "$f" ] && mv "$f" "$T$G/infimech/firmware/" && echo "moved $f to infimech/firmware"; done
if [ -d out-host ] && [ ! -L out-host ]; then
    [ -e "$T$G/klipper-host" ] && die "$G/klipper-host already exists"
    mv out-host "$T$G/klipper-host" && echo "moved out-host to $G/klipper-host"
fi
cd /
install -m 755 "$FILES/klipper_links.sh" "$T$G/infimech/klipper_links.sh" || die "copy failed"
in_t bash $G/infimech/klipper_links.sh
echo "add-ons now linked: $(cd "$T$K/klippy/extras" && for f in infimech_*.py; do echo -n "$f -> $(readlink $f)  "; done)"

say "2. start scripts"
# kp.sh: link the add-ons before Klipper starts
if ! grep -q 'klipper_links.sh' "$T$G/kp.sh"; then
    sed -i 's#^\(\s*\)cd \$R\$G/klipper-new$#&\n\1G=$R$G bash $R$G/infimech/klipper_links.sh > /dev/null 2>\&1#' "$T$G/kp.sh"
fi
grep -q 'klipper_links.sh' "$T$G/kp.sh" || die "could not add the link step to kp.sh"
# host MCU program: new place
sed -i 's#klipper-new/out-host/klipper\.elf#klipper-host/klipper.elf#g' "$T$G/local_mcu.sh" "$T$G/infimech/which_klipper.sh"
grep -q 'klipper-host/klipper.elf' "$T$G/local_mcu.sh" && grep -q 'klipper-host/klipper.elf' "$T$G/infimech/which_klipper.sh" \
    || die "could not update local_mcu.sh / which_klipper.sh"
grep -n -E 'klipper_links|klipper-host' "$T$G/kp.sh" "$T$G/local_mcu.sh" "$T$G/infimech/which_klipper.sh" | sed "s#^$T##"

install -m 755 "$FILES/svc_loop.sh" "$T$G/infimech/svc/svc_loop.sh" || die "copy failed"
install -m 755 "$FILES/supervisorctl" "$T/usr/local/bin/supervisorctl" || die "copy failed"
chmod 755 "$T/usr/local/bin/supervisorctl" "$T$G/infimech/svc/svc_loop.sh" "$T$G/infimech/klipper_links.sh"
# run.sh: each service in its own loop (the original is kept as run.sh.stock)
[ -f "$T/run.sh.stock" ] || cp -p "$T/run.sh" "$T/run.sh.stock"
L="sudo bash /home/gem/infimech/svc/svc_loop.sh"
sed -i -e "s#'sleep 2 \&\& sudo ./kp.sh'#'sleep 2 \&\& $L klipper bash /home/gem/kp.sh'#" \
       -e "s#'sudo ./moon.sh'#'$L moonraker bash /home/gem/moon.sh'#" \
       -e "s#'sudo ./local_mcu.sh'#'$L klipper_mcu bash /home/gem/local_mcu.sh'#" "$T/run.sh"
[ "$(grep -c 'svc_loop.sh' "$T/run.sh")" = 3 ] || die "could not update run.sh"
grep 'send-keys' "$T/run.sh"

say "3. Moonraker: update manager and service control"
mkdir -p "$T$G/infimech/clean"
cat > "$T$G/infimech/clean/infimech_moonraker.conf" <<'EOF'
# Updates from Fluidd (Settings -> Software Updates), added with Debian 12.
# Klipper follows releases only (v0.14.0 -> the next release). After a
# Klipper update Klipper may ask for a firmware update; see
# /home/gem/infimech/firmware.
[update_manager]
channel: dev
refresh_interval: 168
enable_auto_refresh: False
enable_system_updates: True
enable_packagekit: False

[update_manager klipper]
channel: stable

[update_manager fluidd]
type: web
channel: stable
repo: fluidd-core/fluidd
path: /home/gem/fluidd

[update_manager timelapse]
type: git_repo
primary_branch: main
path: /home/gem/moonraker-timelapse
origin: https://github.com/mainsail-crew/moonraker-timelapse.git
managed_services: klipper moonraker
EOF
cat > "$T$G/infimech/moonraker_patch.sh" <<'EOF'
#!/bin/bash
# Adds the update manager and service control to moonraker.conf (safe to
# run again). Inside the chroot:  bash /home/gem/infimech/moonraker_patch.sh [config folder]
CFG=${1:-/home/gem/printer_data/config_new}
M=$CFG/moonraker.conf
[ -f "$M" ] || { echo "no $M"; exit 1; }
[ -f "$CFG/moonraker.conf.before-updates" ] || cp -p "$M" "$CFG/moonraker.conf.before-updates"
sed -i '/^\[machine\]/,/^\[/ s/^provider:.*/provider: supervisord_cli/' "$M"
grep -qxF '[include infimech_moonraker.conf]' "$M" || printf '\n[include infimech_moonraker.conf]\n' >> "$M"
cp /home/gem/infimech/clean/infimech_moonraker.conf "$CFG/infimech_moonraker.conf"
grep -q '^provider: supervisord_cli' "$M" || { echo "could not set the [machine] provider"; exit 1; }
echo "moonraker.conf patched"
EOF
chmod 755 "$T$G/infimech/moonraker_patch.sh"
in_t bash $G/infimech/moonraker_patch.sh || die "moonraker.conf patch failed"
echo "--- allowed services (moonraker.asvc): $(tr '\n' ' ' < "$T$G/printer_data/moonraker.asvc" 2>/dev/null)"
grep -q -x 'klipper_mcu' "$T$G/printer_data/moonraker.asvc" 2>/dev/null || echo "klipper_mcu" >> "$T$G/printer_data/moonraker.asvc"
echo "fluidd: $(cat "$T$G/fluidd/release_info.json" 2>/dev/null || echo 'no release_info.json')"
# apt: keep the firmware compilers off the printer (Moonraker's Klipper
# "recover" would otherwise install ~1.8 GB of them)
cat > "$T/etc/apt/preferences.d/no-firmware-compilers" <<'EOF'
# Firmware is built on a PC (WSL); these don't fit on the printer.
Package: gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi libnewlib-dev libstdc++-arm-none-eabi-newlib gcc-avr avr-libc binutils-avr avrdude
Pin: release *
Pin-Priority: -1
EOF
in_t apt-cache policy gcc-arm-none-eabi 2>/dev/null | grep -i candidate

say "3b. fixes found later on the printer"
# /home/gem itself is a git folder (the vendor's KIAUH copy): Moonraker then
# refuses to manage Fluidd
if [ -d "$T$G/.git" ]; then
    mv "$T$G/.git" "$T$G/infimech/backup/home-kiauh.git" && echo "moved /home/gem/.git to infimech/backup/home-kiauh.git"
fi
# describes the services for Moonraker (no real supervisord)
printf '%s\n' '; Not used by a real supervisord: describes the services for Moonraker.' \
    '; They are kept running by /home/gem/infimech/svc/svc_loop.sh (see /run.sh)' \
    '; and controlled through /usr/local/bin/supervisorctl.' \
    '[program:klipper]' 'command=/home/gem/kp.sh' \
    '[program:moonraker]' 'command=/home/gem/moon.sh' \
    '[program:klipper_mcu]' 'command=/home/gem/local_mcu.sh' > "$T/etc/supervisord.conf"
# Moonraker must find the supervisorctl stand-in in /usr/local/bin
grep -q '^export PATH=/usr/local/sbin:/usr/local/bin' "$T$G/moon.sh" \
    || sed -i '1a export PATH=/usr/local/sbin:/usr/local/bin:$PATH' "$T$G/moon.sh"
# Tina's host name, so sudo stops saying "unable to resolve host"
HN=${TINA_HOSTNAME:-Octopus}
grep -q "[[:space:]]$HN\$" "$T/etc/hosts" || echo "127.0.1.1 $HN" >> "$T/etc/hosts"
echo "fixes applied (hosts: $HN)"

say "4. git status (Moonraker needs 0 changes to allow updates)"
for r in klipper-new moonraker moonraker-timelapse; do
    n=$(git -c safe.directory='*' -C "$T$G/$r" status --porcelain 2>/dev/null | wc -l)
    echo "$r: $n changes $(git -c safe.directory='*' -C "$T$G/$r" describe --tags --always 2>/dev/null) on $(git -c safe.directory='*' -C "$T$G/$r" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    git -c safe.directory='*' -C "$T$G/$r" status --porcelain 2>/dev/null | head -n 10
done

say "5. test: Klipper + Moonraker running together (no printer attached)"
rm -rf "$T/tmp/ktest" "$T/tmp/mtest"
cp -a "$T$G/printer_data/config_new" "$T/tmp/ktest"
sed -i 's/^manage_thresholds: .*/manage_thresholds: off/' "$T/tmp/ktest/infimech.cfg"
mkdir -p "$T/tmp/mtest/logs" "$T/tmp/mtest/gcodes" "$T/tmp/mtest/comms"
cp -a "$T$G/printer_data/config_new" "$T/tmp/mtest/config"
cp -a "$T$G/printer_data/database" "$T/tmp/mtest/database"
cp -a "$T$G/printer_data/moonraker.asvc" "$T/tmp/mtest/" 2>/dev/null
echo "supervisorctl before start: $(in_t supervisorctl status | tr -s ' ' | tr '\n' ';')"
chroot "$T" sh -c "cd $K && exec $G/klippy-env/bin/python klippy/klippy.py /tmp/ktest/printer.cfg -I /tmp/printer -a $G/printer_data/comms/klippy.sock -l /tmp/ktest/klippy.log" > "$W/ktest.out" 2>&1 &
PIDS="$!"
chroot "$T" sh -c "cd $G/moonraker && exec $G/moonraker-env/bin/python moonraker/moonraker.py -d /tmp/mtest" > "$W/mtest.out" 2>&1 &
PIDS="$PIDS $!"
up=""
for i in $(seq 1 90); do
    curl -s -m 2 http://127.0.0.1:7125/server/info 2>/dev/null | grep -q '"klippy_connected": *true' && up=1 && break
    sleep 2
done
[ -n "$up" ] || { echo "Klipper/Moonraker did not connect within 3 minutes"; tail -n 20 "$W/mtest.out"; tail -n 20 "$T/tmp/ktest/klippy.log"; }
echo "supervisorctl now: $(in_t supervisorctl status | tr -s ' ' | tr '\n' ';')"
echo "checking for updates (git, GitHub, apt; a few minutes in the emulator)..."
curl -s -m 600 -X POST http://127.0.0.1:7125/machine/update/refresh > "$W/m_refresh.json" 2>&1
python3 - <<'PYEOF'
import json, urllib.request
def get(p):
    try:
        return json.load(urllib.request.urlopen("http://127.0.0.1:7125" + p, timeout=60))["result"]
    except Exception as e:
        return {"error": str(e)}
i = get("/server/info")
print("klippy connected:", i.get("klippy_connected"), " state:", i.get("klippy_state"), "(startup/error expected: no printer)")
print("failed components:", i.get("failed_components"), " warnings:", i.get("warnings"))
p = get("/printer/info")
print("klipper:", p.get("software_version"), p.get("klipper_path"), p.get("python_path"))
s = get("/machine/system_info").get("system_info", {})
print("services Moonraker can control:", s.get("available_services"))
print("service states:", {k: v.get("active_state") for k, v in (s.get("service_state") or {}).items()})
u = get("/machine/update/status")
for name, v in (u.get("version_info") or {}).items():
    if name == "system":
        print(f"  system: {v.get('package_count')} Debian packages can be updated")
        continue
    keys = ["version", "remote_version", "channel", "is_valid", "is_dirty", "corrupt", "detached", "warnings", "anomalies"]
    print(f"  {name}: " + ", ".join(f"{k}={v.get(k)}" for k in keys if k in v))
if "error" in u:
    print("update status:", u)
PYEOF
echo "--- moonraker.log warnings/errors:"
grep -i -E "warning|error|exception|failed" "$T/tmp/mtest/logs/moonraker.log" 2>/dev/null | grep -v -i 'klippy.*not connected\|mcu' | cut -c1-200 | tail -n 15
echo "--- klippy.log (first errors):"
grep -i -E "error|exception" "$T/tmp/ktest/klippy.log" 2>/dev/null | grep -v -i "unable to connect\|serial\|ttyS\|by-id\|klipper_host_mcu" | head -n 5

say "sizes"
echo "total: $(du -sh --exclude=proc --exclude=sys --exclude=dev "$T" | cut -f1)"
say "part C done in $(( ($(date +%s) - START) / 60 )) minutes"
