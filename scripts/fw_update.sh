#!/bin/bash
# fw_update.sh - bring the Infimech TX's Klipper firmware up to the installed
# Klipper version, after Klipper was updated (for example from Fluidd):
#   - host MCU program (the "rpi" MCU, runs on the printer): rebuilt here from
#     the installed Klipper, into /home/gem/klipper-host
#   - STM32 mainboard firmware: built on the PC with fw_build.sh, copied into
#     /home/gem/infimech/firmware, flashed here through the STM32's ROM
#     bootloader (DFU), read back and compared
#
# Run inside the Debian chroot as root, with the printer idle. From the PC
# (Command Prompt):
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/firmware/fw_update.sh --check" > fw_check.txt 2>&1
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/firmware/fw_update.sh" > fw_update.txt 2>&1
#
# Options:
#   --check        checks only (includes an offline config check); changes nothing
#   --host-only    rebuild the host MCU program; do not flash the STM32
#   --stm32-only   flash the STM32; do not rebuild the host MCU program
#   FILE.bin       flash this file (in the firmware folder) instead of the one
#                  that matches the installed Klipper
# Settings (environment):
#   FORCE=1              flash a .bin whose version is not the installed Klipper's
#   SKIP_CONFIG_CHECK=1  skip the offline config check
#
# The update itself runs in the background, so a dropped SSH connection does
# not stop it half-way; the window only shows its log:
#   /home/gem/infimech/firmware/fw_update.log
# Old host MCU programs are moved to /home/gem/infimech/backup/, never deleted.
# If the STM32 is left in its bootloader (outputs off, safe), run this again.
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
shopt -s nullglob

G=${G:-/home/gem}
K=$G/klipper-new
FWD=$G/infimech/firmware
HOST=$G/klipper-host
HOSTCFG=$FWD/config.host
PY=$G/klippy-env/bin/python
LOGS=$G/printer_data/logs
BK=$G/infimech/backup
GPIO=${GPIO:-/sys/class/gpio}
SERDIR=${SERDIR:-/dev/serial/by-id}
MOON=${MOON:-http://127.0.0.1:7125}
FLAGS=${FLAGS:-/run/infimech}
BOOT0=228
RESET=142
LOG=$FWD/fw_update.log
LOCK=$FLAGS/fw_update.lock
TS=$(date +%Y%m%d-%H%M%S)

CHECK=0; DO_HOST=1; DO_STM32=1; BIN=""
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        --host-only) DO_STM32=0 ;;
        --stm32-only) DO_HOST=0 ;;
        -*) echo "ERROR: unknown option $a"; exit 1 ;;
        *) BIN=$a ;;
    esac
done
[ $DO_HOST = 1 ] || [ $DO_STM32 = 1 ] || { echo "ERROR: --host-only and --stm32-only together leave nothing to do"; exit 1; }

# ------------------------------------------------ start the background run
if [ $CHECK = 0 ] && [ "${FW_WORKER:-0}" != 1 ]; then
    [ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }
    [ -d "$FWD" ] || { echo "ERROR: $FWD not found - run this inside the chroot (chroot /server/tmp bash ...)"; exit 1; }
    mkdir -p "$FLAGS"
    mkdir "$LOCK" 2>/dev/null || {
        echo "ERROR: fw_update.sh is already running (or $LOCK was left behind; it is gone after a power cycle)"
        exit 1; }
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
    : > "$LOG"
    FW_WORKER=1 setsid -f bash "$0" "$@" >> "$LOG" 2>&1 < /dev/null \
        || { rmdir "$LOCK"; echo "ERROR: could not start the background run"; exit 1; }
    echo "Runs in the background; this shows its log ($LOG)."
    echo "If the connection drops, the update carries on. Read the log afterwards with:"
    echo "  ssh root@<PRINTER_IP> \"cat /server/tmp$LOG\""
    n=0
    while :; do
        fin=0; grep -q '^=== FW_UPDATE_END' "$LOG" && fin=1
        t=$(wc -l < "$LOG")
        if [ "$t" -gt "$n" ]; then sed -n "$((n + 1)),${t}p" "$LOG"; n=$t; fi
        [ $fin = 1 ] && break
        sleep 1
    done
    rc=$(sed -n 's/^=== FW_UPDATE_END rc=//p' "$LOG" | tail -n 1)
    exit "${rc:-1}"
fi

# ------------------------------------------------ helpers
STAGE=checks   # checks -> stopped -> dfu -> flashing -> flashed -> started
note() { echo "$(date '+%H:%M:%S') $*"; }
say() { echo; echo "$(date '+%H:%M:%S') === $*"; }
end() {
    echo "=== FW_UPDATE_END rc=$1"
    [ $CHECK = 1 ] || rmdir "$LOCK" 2>/dev/null
    exit "$1"
}
mask() { sed -E 's/(stm32f072xb_)[0-9A-Fa-f]+/\1<chip id>/g'; }

dict_get() {   # dict_get <file> <version|build_versions|CONFIG KEY>
    python3 - "$1" "$2" <<'EOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
k = sys.argv[2]
v = d.get(k) if k in ("version", "build_versions") else d.get("config", {}).get(k)
print("" if v is None else v)
EOF
}
ver_hash() { local v=${1%-dirty}; echo "${v##*-g}"; }   # v0.14.0-0-gc9559fa -> c9559fa
matches_head() { local h; h=$(ver_hash "$1"); [ ${#h} -ge 7 ] && [[ $HEAD == "$h"* ]]; }

moon_status() {   # prints: klippy state, print state, mcu version, host mcu version
    python3 - "$MOON" "$1" <<'EOF' 2>/dev/null || printf 'unreachable\n-\n-\n-\n'
import json, sys, urllib.parse, urllib.request
base, host = sys.argv[1], sys.argv[2]
def get(path):
    return json.load(urllib.request.urlopen(base + path, timeout=5))["result"]
try:
    # klippy_state: ready, startup, shutdown, error or disconnected
    state = get("/server/info").get("klippy_state", "unknown")
except Exception:
    print("unreachable\n-\n-\n-"); sys.exit(0)
ps = mv = hv = "-"
if state == "ready":
    try:
        q = "/printer/objects/query?print_stats=state&mcu=mcu_version&" \
            + urllib.parse.quote("mcu " + host) + "=mcu_version"
        st = get(q)["status"]
        ps = st.get("print_stats", {}).get("state", "-")
        mv = st.get("mcu", {}).get("mcu_version", "-")
        hv = st.get("mcu " + host, {}).get("mcu_version", "-")
    except Exception:
        ps = "unknown"
print(state); print(ps); print(mv); print(hv)
EOF
}

usb_serial() { local s=("$SERDIR"/usb-Klipper_stm32f072xb_*-if00); [ ${#s[@]} = 1 ] && echo "${s[0]}"; }
dfu_present() { dfu-util -l 2>/dev/null | grep -q '0483:df11'; }

svc_state() { supervisorctl status "$1" 2>/dev/null | awk '{print $2; exit}'; }
stop_svc() {
    supervisorctl stop "$1" > /dev/null
    for i in $(seq 30); do
        [ "$(svc_state "$1")" = STOPPED ] && { note "$1 stopped"; return 0; }
        sleep 1
    done
    return 1
}
start_svcs() {
    supervisorctl start klipper_mcu > /dev/null
    sleep 2
    supervisorctl start klipper > /dev/null
    note "klipper_mcu and klipper started again"
}

gpio_setup() {   # <num> <high|low>: output with a defined level, no glitch
    [ -d "$GPIO/gpio$1" ] || echo "$1" > "$GPIO/export"
    echo "$2" > "$GPIO/gpio$1/direction"
}
reset_stm32() {  # <boot0 value>, same order as Tina's update_stm32.sh
    gpio_setup $RESET high
    gpio_setup $BOOT0 low
    echo "$1" > "$GPIO/gpio$BOOT0/value"
    echo 0 > "$GPIO/gpio$RESET/value"
    sleep 0.1
    echo 1 > "$GPIO/gpio$RESET/value"
}
gpio_release() {
    echo $BOOT0 > "$GPIO/unexport" 2>/dev/null
    echo $RESET > "$GPIO/unexport" 2>/dev/null
}
wait_usb() {     # <seconds>
    local i
    for i in $(seq $(($1 * 2))); do
        [ -n "$(usb_serial)" ] && return 0
        sleep 0.5
    done
    return 1
}

fail() {
    echo "$(date '+%H:%M:%S') ERROR: $*"
    case $STAGE in
        checks)
            echo "Nothing running was changed." ;;
        stopped)
            echo "The STM32 was not touched."; start_svcs ;;
        dfu)
            echo "The STM32 did not enter its bootloader; restarting it with its current firmware."
            reset_stm32 0; sleep 0.5; gpio_release
            if wait_usb 10; then start_svcs
            else echo "The STM32 did not come back on USB. Klipper stays stopped. Power-cycle the printer and send me this log."; fi ;;
        flashing)
            echo "The STM32 is left in its ROM bootloader (outputs off, safe). Klipper stays stopped."
            echo "Run this script again (it can flash from the bootloader). Do not power-cycle first: the STM32"
            echo "would then start the incomplete firmware; if that happened, run this script again anyway." ;;
        flashed)
            echo "The firmware was written and verified, but the STM32 did not come back on USB."
            echo "Klipper stays stopped. Power-cycle the printer and send me this log." ;;
        started)
            echo "Klipper was started again; see the messages above." ;;
    esac
    end 1
}

# ------------------------------------------------ checks
[ $CHECK = 1 ] && say "CHECK ONLY - nothing will be changed" || say "Firmware update started $(date '+%F %T')"
say "1. checks"
[ "$(id -u)" = 0 ] || fail "run as root"
[ -f "$K/klippy/klippy.py" ] || fail "$K not found - run this inside the chroot (chroot /server/tmp bash ...)"
need="git python3 md5sum supervisorctl setsid"
[ $DO_HOST = 1 ] && need="$need make gcc"
[ $DO_STM32 = 1 ] && need="$need dfu-util cmp"
for t in $need; do command -v "$t" > /dev/null || fail "$t is missing (apt install it)"; done
[ -x "$PY" ] || fail "$PY missing"

HEAD=$(git -C "$K" rev-parse HEAD 2>/dev/null) || fail "cannot read the installed Klipper version"
KDESC=$(git -C "$K" describe --always --tags --long --dirty 2>/dev/null)
note "installed Klipper:     $KDESC (commit ${HEAD:0:10})"

CFG=$(grep -o "$G/printer_data/[^ ]*/printer.cfg" "$G/kp.sh" 2>/dev/null | head -n 1)
[ -f "${CFG:-}" ] || CFG=$G/printer_data/config_new/printer.cfg
[ -f "$CFG" ] || fail "Klipper config not found ($CFG)"
HOSTMCU=$(grep -h -o -E '^\[mcu [A-Za-z0-9_]+\]' "$(dirname "$CFG")"/*.cfg 2>/dev/null \
          | sed -E 's/^\[mcu ([^]]+)\]/\1/' | sort -u)
[ "$(echo "$HOSTMCU" | grep -c .)" = 1 ] || fail "expected one [mcu <name>] section in $(dirname "$CFG"), found: ${HOSTMCU:-none}"
note "config:                $CFG (host MCU section: [mcu $HOSTMCU])"

{ read -r KSTATE; read -r PSTATE; read -r MCUV; read -r HOSTV; } < <(moon_status "$HOSTMCU")
note "Klipper state:         $KSTATE"
case $KSTATE in
    unreachable) [ "${FORCE:-0}" = 1 ] || fail "Moonraker does not answer, so the print state is unknown (FORCE=1 to go on anyway)" ;;
    ready)
        note "print state:           $PSTATE"
        case $PSTATE in
            printing|paused) fail "the printer is $PSTATE - finish or cancel the print first" ;;
            unknown) [ "${FORCE:-0}" = 1 ] || fail "cannot read the print state (FORCE=1 to go on anyway)" ;;
        esac ;;
    *) note "print state:           Klipper is not ready, so nothing is printing" ;;
esac
LASTMCU=$(grep -a "Loaded MCU 'mcu' " "$LOGS/klippy.log" 2>/dev/null | tail -n 1 | sed -E "s/.*\(([^ ]+) \/.*/\1/")
[ "$MCUV" != - ] || MCUV=${LASTMCU:-unknown}
note "STM32 firmware now:    $MCUV"
OLDHOSTV=$(dict_get "$HOST/klipper.dict" version)
note "host MCU program now:  ${OLDHOSTV:-unknown} (running: $HOSTV)"

SERIAL=$(usb_serial)
if [ -n "$SERIAL" ]; then
    note "STM32 on USB:          $(basename "$SERIAL" | mask)"
elif [ $DO_STM32 = 1 ] && dfu_present; then
    note "STM32 on USB:          in its ROM bootloader (an earlier flash did not finish) - it will be flashed"
elif [ $DO_STM32 = 1 ] && [ "$KSTATE" != ready ]; then
    note "STM32 on USB:          NOT FOUND (no firmware running?) - flashing will put it into its bootloader"
else
    fail "the STM32 is not on USB as usb-Klipper_stm32f072xb_<chip id>-if00"
fi

if [ $DO_STM32 = 1 ]; then
    if [ -z "$BIN" ]; then
        for d in "$FWD"/klipper-*-stm32f072-mainboard.dict; do
            matches_head "$(dict_get "$d" version)" && BIN=${d%.dict}.bin
        done
        if [ -z "$BIN" ]; then
            echo "STM32 firmware files in $FWD:"
            for d in "$FWD"/klipper-*-stm32f072-mainboard.dict; do echo "  ${d##*/}: $(dict_get "$d" version)"; done
            fail "no STM32 firmware for Klipper $KDESC in $FWD - build it on the PC (fw_build.sh) and copy fw-<version>.tar here"
        fi
    fi
    [[ $BIN == /* ]] || BIN=$FWD/$BIN
    DICT=${BIN%.bin}.dict
    for f in "$BIN" "$BIN.md5" "$DICT"; do [ -f "$f" ] || fail "missing $f"; done
    (cd "$(dirname "$BIN")" && md5sum -c --quiet "$(basename "$BIN").md5") || fail "checksum mismatch: $BIN"
    BVER=$(dict_get "$DICT" version)
    [ "$(dict_get "$DICT" MCU)" = stm32f072xb ] && [ "$(dict_get "$DICT" CLOCK_FREQ)" = 48000000 ] \
        || fail "$DICT is not for this mainboard"
    case $BVER in *-dirty|"") fail "firmware version '$BVER' is not a clean Klipper build" ;; esac
    if ! matches_head "$BVER"; then
        [ "${FORCE:-0}" = 1 ] || fail "firmware $BVER is not the installed Klipper $KDESC (FORCE=1 to flash it anyway)"
        note "WARNING: firmware $BVER is not the installed Klipper $KDESC (FORCE=1)"
    fi
    FWSIZE=$(stat -c %s "$BIN")
    [ "$FWSIZE" -gt 1024 ] && [ "$FWSIZE" -le 131072 ] || fail "$BIN has an odd size ($FWSIZE bytes)"
    note "STM32 firmware to use: ${BIN##*/} ($BVER, $FWSIZE bytes, md5 OK)"
    note "                       $(dict_get "$DICT" build_versions)"
    [ -w "$GPIO/export" ] || fail "$GPIO/export is not writable"
    for n in $BOOT0 $RESET; do [ -d "$GPIO/gpio$n" ] && note "note: gpio$n is already exported (left over from an earlier run?)"; done
fi
if [ $DO_HOST = 1 ]; then
    [ -f "$HOSTCFG" ] || fail "missing $HOSTCFG (host MCU build settings)"
    grep -qx 'CONFIG_MACH_LINUX=y' "$HOSTCFG" || fail "$HOSTCFG is not a host MCU (Linux) configuration"
    FREE=$(df -Pm "$G" | awk 'NR == 2 {print $4}')
    [ "${FREE:-0}" -ge 200 ] || fail "only ${FREE:-?} MB free in $G"
    note "host MCU build:        from $K with ${HOSTCFG##*/}, $FREE MB free"
fi

config_check() {  # <stm32 dict> <host dict>
    [ "${SKIP_CONFIG_CHECK:-0}" = 1 ] && { note "offline config check skipped (SKIP_CONFIG_CHECK=1)"; return 0; }
    local d=$FWD/check rc
    mkdir -p "$d"
    : > "$d/empty.gcode"
    note "offline config check (batch mode, no hardware used; about a minute)"
    (cd "$K" && "$PY" klippy/klippy.py "$CFG" -i "$d/empty.gcode" -o "$d/check.out" \
        -d "$1" -d "$HOSTMCU=$2" -l "$d/check.log" > "$d/check.console" 2>&1)
    rc=$?
    # batch mode exits with an error code unless Klipper reached "ready"
    if [ $rc = 0 ]; then
        note "offline config check passed"
        return 0
    fi
    note "offline config check FAILED (exit code $rc); last lines of its log:"
    grep -a -v -E 'Exception on read|^Traceback|^  File|^    |Error: \[Errno 2\]|^FileNotFoundError' "$d/check.log" | tail -n 20 | mask
    return 1
}

if [ $CHECK = 1 ]; then
    if [ $DO_STM32 = 1 ] && [ -f "$HOST/klipper.dict" ]; then
        config_check "$DICT" "$HOST/klipper.dict" || fail "the config does not pass with the new STM32 firmware (log: $FWD/check/check.log)"
    else
        note "offline config check: runs during the update, after the host MCU build"
    fi
    say "CHECK PASSED - nothing was changed"
    echo "Without --check this would:"
    [ $DO_HOST = 1 ] && echo "  - build the host MCU program from $KDESC into $G/klipper-host.new (Klipper keeps running)"
    echo "  - run the offline config check with the new firmware"
    echo "  - stop Klipper$([ $DO_HOST = 1 ] && echo ' and the host MCU program') (Moonraker, Fluidd and the screen keep running)"
    [ $DO_HOST = 1 ] && echo "  - move $HOST to $BK/ and put the new build in its place"
    [ $DO_STM32 = 1 ] && echo "  - flash ${BIN##*/} into the STM32 (DFU), read it back and compare"
    echo "  - start them again and wait until Klipper is ready"
    end 0
fi

# ------------------------------------------------ host MCU build (Klipper keeps running)
NEWHOST=$G/klipper-host.new
if [ $DO_HOST = 1 ]; then
    say "2. building the host MCU program (a few minutes)"
    mkdir -p "$BK"
    [ -e "$NEWHOST" ] && mv "$NEWHOST" "$BK/klipper-host.new-left-over-$TS" && note "moved an old $NEWHOST to $BK/"
    mkdir -p "$NEWHOST"
    cp "$HOSTCFG" "$NEWHOST/config.host"
    BEFORE=$(git -C "$K" status --porcelain --untracked-files=no)
    { make -C "$K" KCONFIG_CONFIG="$NEWHOST/config.host" OUT="$NEWHOST/" olddefconfig \
      && make -C "$K" KCONFIG_CONFIG="$NEWHOST/config.host" OUT="$NEWHOST/" -j"$(nproc)"; } \
        > "$NEWHOST/build.log" 2>&1 || { tail -n 25 "$NEWHOST/build.log"; fail "host MCU build failed (log: $NEWHOST/build.log)"; }
    [ "$(git -C "$K" status --porcelain --untracked-files=no)" = "$BEFORE" ] || note "WARNING: the build changed files in $K"
    [ -x "$NEWHOST/klipper.elf" ] && [ -f "$NEWHOST/klipper.dict" ] || fail "the build made no klipper.elf"
    NEWHOSTV=$(dict_get "$NEWHOST/klipper.dict" version)
    matches_head "$NEWHOSTV" || fail "new host MCU program has version $NEWHOSTV, not $KDESC"
    note "built: $NEWHOSTV ($(dict_get "$NEWHOST/klipper.dict" build_versions))"
fi

say "3. offline config check"
if [ $DO_STM32 = 1 ]; then SD=$DICT
else
    SD=""
    for d in "$FWD"/klipper-*-stm32f072-mainboard.dict; do matches_head "$(dict_get "$d" version)" && SD=$d; done
fi
HD=$HOST/klipper.dict; [ $DO_HOST = 1 ] && HD=$NEWHOST/klipper.dict
if [ -n "$SD" ]; then
    config_check "$SD" "$HD" || fail "the config does not pass with the new firmware (log: $FWD/check/check.log)"
else
    note "skipped: no STM32 firmware file for $KDESC to check against"
fi

# ------------------------------------------------ stop, install, flash
say "4. stopping Klipper (Moonraker, Fluidd and the screen keep running)"
LOGLINES=$(wc -l < "$LOGS/klippy.log" 2>/dev/null || echo 0)
STAGE=stopped
stop_svc klipper || fail "Klipper did not stop"
if [ $DO_HOST = 1 ]; then stop_svc klipper_mcu || fail "the host MCU program did not stop"; fi

if [ $DO_HOST = 1 ]; then
    say "5. installing the new host MCU program"
    OLDNAME=$BK/klipper-host-${OLDHOSTV:-old}-$TS
    mv "$HOST" "$OLDNAME" || fail "could not move $HOST"
    if ! mv "$NEWHOST" "$HOST"; then
        mv "$OLDNAME" "$HOST"
        fail "could not move the new build into place (the old one is back)"
    fi
    note "$HOST: $NEWHOSTV (old one: $OLDNAME)"
fi

if [ $DO_STM32 = 1 ]; then
    say "6. flashing the STM32"
    STAGE=dfu
    note "entering the ROM bootloader (BOOT0 high, reset pulse)"
    reset_stm32 1
    sleep 0.5
    for i in $(seq 20); do dfu_present && break; sleep 0.5; done
    dfu_present || fail "the STM32 did not appear in DFU mode"
    STAGE=flashing
    note "DFU device found, writing ${BIN##*/}"
    dfu-util -d 0483:df11 -a 0 -s 0x08000000 -D "$BIN" > "$FWD/flash.log" 2>&1 \
        || { tail -n 15 "$FWD/flash.log"; fail "write failed (log: $FWD/flash.log)"; }
    note "reading back and comparing"
    RB=/tmp/fw_readback-$TS.bin
    dfu-util -d 0483:df11 -a 0 -s 0x08000000:"$FWSIZE" -U "$RB" >> "$FWD/flash.log" 2>&1 \
        || { tail -n 15 "$FWD/flash.log"; fail "read-back failed (log: $FWD/flash.log)"; }
    cmp "$BIN" "$RB" || fail "VERIFY FAILED: the flash content differs from ${BIN##*/}"
    note "verify OK ($FWSIZE bytes identical)"
    STAGE=flashed
    note "starting the new firmware (BOOT0 low, reset pulse)"
    reset_stm32 0
    sleep 0.5
    gpio_release
    wait_usb 15 || fail "timeout waiting for USB"
    NEWSERIAL=$(usb_serial)
    note "STM32 is back on USB: $(basename "$NEWSERIAL" | mask)"
    [ -z "$SERIAL" ] || [ "$NEWSERIAL" = "$SERIAL" ] || note "WARNING: the USB name changed - the [mcu] serial in the config must match it"
fi

# ------------------------------------------------ start and confirm
say "7. starting Klipper"
STAGE=started
start_svcs
S=unreachable
for _ in $(seq 40); do
    sleep 3
    { read -r S; read -r _; read -r NMCUV; read -r NHOSTV; } < <(moon_status "$HOSTMCU")
    [ "$S" = ready ] && break
done
note "Klipper state: $S"
tail -n +"$((LOGLINES + 1))" "$LOGS/klippy.log" 2>/dev/null | grep -a -E "^Loaded MCU|^Git version" | tail -n 3 | mask
if [ "$S" != ready ]; then
    tail -n +"$((LOGLINES + 1))" "$LOGS/klippy.log" 2>/dev/null | tail -n 25 | mask
    fail "Klipper is not ready after 2 minutes; nothing is heating"
fi
ok=1
matches_head "$NMCUV" || { note "WARNING: STM32 reports $NMCUV, installed Klipper is $KDESC"; ok=0; }
matches_head "$NHOSTV" || { note "WARNING: host MCU reports $NHOSTV, installed Klipper is $KDESC"; ok=0; }
say "DONE - Klipper $KDESC is ready"
note "STM32 firmware:       $NMCUV"
note "host MCU program:     $NHOSTV"
[ $ok = 1 ] && note "both match the installed Klipper" \
             || note "not everything matches: see the warnings above"
echo "Check temperatures in Fluidd before heating anything."
end $((1 - ok))
