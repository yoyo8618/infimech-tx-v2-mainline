#!/bin/bash
# Choose the touchscreen program, now and for every power-on:
#   chroot /server/tmp bash /home/gem/infimech/screen.sh helix    HelixScreen
#   chroot /server/tmp bash /home/gem/infimech/screen.sh stock    stock screen
#   chroot /server/tmp bash /home/gem/infimech/screen.sh status
# HelixScreen is only used with the new Klipper: if the printer ever boots
# stock Klipper (stock STM32 firmware), the stock screen runs regardless.
# Installed by step 7 (7_screen.sh)
set -uo pipefail
G=${G:-/home/gem}
PKG=$G/infimech
CONF=$PKG/screen.conf
RUNNER=$PKG/screen/helix_run.sh
CFG=$G/printer_data/config_new
LOGDIR=$G/printer_data/logs
MOD=$G/klipper-new/klippy/extras/infimech_bed_sensor.py
MOON=${MOON:-http://127.0.0.1:7125}
die() { echo "ERROR: $*" >&2; exit 1; }

names() {   # running screen programs
    local p c out=""
    for p in /proc/[0-9]*; do
        c=$(cat "$p/comm" 2>/dev/null)
        case "$c" in
            FdmPrinter) out="$out stock screen (pid ${p#/proc/})," ;;
            helix-screen-fb|helix-screen) out="$out HelixScreen (pid ${p#/proc/})," ;;
        esac
    done
    echo "${out:- none}"
}

print_state() {
    python3 - "$MOON" <<'PYEOF'
import json, sys, urllib.request
try:
    r = urllib.request.urlopen(sys.argv[1] + "/printer/objects/query?print_stats=state", timeout=5)
    print(json.load(r)["result"]["status"]["print_stats"]["state"])
except Exception:
    print("unknown")
PYEOF
}

[ "${SKIP_USER_CHECK:-0}" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root inside the chroot"
case "${1:-status}" in
helix)
    # Klipper must set the bed sensor thresholds when the stock screen is gone
    grep -q '^manage_thresholds: auto' "$CFG/infimech.cfg" 2>/dev/null \
        || die "manage_thresholds is not 'auto' in $CFG/infimech.cfg - nothing changed"
    grep -q 'i2c_mutex' "$MOD" 2>/dev/null \
        || die "the bed sensor module is too old (no i2c_mutex) - nothing changed"
    [ -x "$G/helixscreen/bin/helix-screen-fbdev" ] || [ -x "$G/helixscreen/bin/helix-screen" ] \
        || die "HelixScreen is not installed in $G/helixscreen"
    [ -x "${BRI:-/usr/bin/brightness}" ] || die "/usr/bin/brightness (backlight helper) is missing"
    s=$(print_state)
    case "$s" in printing|paused) die "the printer is $s - switch screens when it is idle" ;; esac
    echo helix > "$CONF.new" && mv "$CONF.new" "$CONF"
    sync
    echo "screen.conf: helix (also at every power-on)"
    setsid -f bash "$RUNNER" now > /dev/null 2>&1 < /dev/null
    sleep 8
    echo "running:$(names)"
    ;;
stock)
    echo stock > "$CONF.new" && mv "$CONF.new" "$CONF"
    sync
    echo "screen.conf: stock (also at every power-on)"
    bash "$RUNNER" stock
    sleep 5
    echo "running:$(names)"
    ;;
status)
    echo "screen.conf: $(cat "$CONF" 2>/dev/null || echo 'missing (= stock)')"
    echo "running:$(names)"
    echo "== last screen.log lines"
    tail -n 12 "$LOGDIR/screen.log" 2>/dev/null
    ;;
*)
    echo "usage: screen.sh helix|stock|status"; exit 2 ;;
esac
