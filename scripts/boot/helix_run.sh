#!/bin/bash
# Runs HelixScreen in place of the stock screen, and keeps it running.
# Started inside the Debian chroot, as root:
#   helix_run.sh boot   by kp.sh at power-on (only when the new Klipper
#                       starts, and only if screen.conf says "helix"):
#                       waits for Tina to start the stock screen, stops it,
#                       starts HelixScreen
#   helix_run.sh now    by screen.sh helix: stops the stock screen at once
#   helix_run.sh stock  by screen.sh stock: stops HelixScreen (and this
#                       script's running copy), starts the stock screen
# If HelixScreen stops 3 times within 5 minutes, the stock screen is
# started again and this script ends (logged in screen.log).
# Updates from Fluidd (Moonraker [update_manager helixscreen], type web):
# Moonraker deletes $APP and unpacks the new release. So the user's files
# live in printer_data/config/helixscreen/ and $APP/config/ only links to
# them (link_user_config, before every start), and a running HelixScreen is
# restarted once the new release is fully unpacked (watch_update).
# Installed by /home/gem/infimech/screen_install.sh
G=${G:-/home/gem}
APP=${APP:-$G/helixscreen}
CONF=${CONF:-$G/infimech/screen.conf}
LOGDIR=${LOGDIR:-$G/printer_data/logs}
LOG=$LOGDIR/screen.log              # what this script did
HLOG=$LOGDIR/helixscreen.log        # HelixScreen's own log (previous run: .1)
RUN=${RUN:-/run/helixscreen}        # shared with Tina; also the Wi-Fi reply socket
PIDFILE=$RUN/helix_run.pid
GPIO=${GPIO:-/sys/class/gpio/gpio232/value}   # backlight switch, 1 = on
BIN=helix-screen-fbdev              # set by pick_bin before every start
WAIT_STOCK=${WAIT_STOCK:-90}        # boot: seconds to wait for the stock screen
WATCH_STOCK=${WATCH_STOCK:-120}     # boot: keep stopping it for this long
MAX_FAILS=3
FAIL_WINDOW=300
PDH=${PDH:-$G/printer_data/config/helixscreen}   # user files (editable in Fluidd)
# the same lists as HelixScreen's own installer (refresh-service-units.sh)
USER_FILES="settings.json helixscreen.env .disabled_services tool_spools.json crash_history.json user_filaments.json"
USER_DIRS="custom_images themes printer_database.d"
UPDATE_POLL=${UPDATE_POLL:-10}      # seconds between update checks

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# processes named FdmPrinter (Tina's /proc is shared with the chroot)
stock_pids() {
    local p
    for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = FdmPrinter ] && echo "${p#/proc/}"
    done
}

stop_stock() {
    local pids i p alive
    pids=$(stock_pids)
    [ -z "$pids" ] && return 0
    log "stopping the stock screen (pid $pids)"
    kill $pids 2>/dev/null
    # wait for these processes only (a new one may be starting meanwhile)
    i=0
    while [ $i -lt 10 ]; do
        alive=""
        for p in $pids; do [ -d /proc/$p ] && alive="$alive $p"; done
        [ -z "$alive" ] && return 0
        sleep 0.5; i=$((i + 1))
    done
    kill -9 $alive 2>/dev/null
    return 0
}

# Tina's boot animation (/etc/init.d/show_start.sh) draws frames on the
# display until the stock screen has finished loading; stop it before
# HelixScreen takes the display, or it keeps drawing over HelixScreen.
stop_splash() {
    local p a
    for p in /proc/[0-9]*; do
        { mapfile -d "" -t a < "$p/cmdline"; } 2>/dev/null || continue
        [ "${a[1]:-}" = /etc/init.d/show_start.sh ] || continue
        kill "${p#/proc/}" 2>/dev/null && log "stopped the boot animation (pid ${p#/proc/})"
    done
    return 0
}

# HelixScreen's processes: by name (cut to 15 characters: helix-screen-fb up
# to v1.0.x, helix-screen from v1.1.0), plus any process that holds its lock
# file $APP/config/.helix-screen.lock (a copy HelixScreen relaunched itself)
helix_pids() {
    local p c f
    for p in /proc/[0-9]*; do
        c=$(cat "$p/comm" 2>/dev/null)
        if [ "$c" = helix-screen-fb ] || [ "$c" = helix-screen ]; then
            echo "${p#/proc/}"
            continue
        fi
        for f in "$p"/fd/*; do
            case "$(readlink "$f" 2>/dev/null)" in
                */helix-screen.lock|*/.helix-screen.lock) echo "${p#/proc/}"; break ;;
            esac
        done
    done
}

stop_helix() {
    local pids i p alive
    pids=$(helix_pids)
    [ -z "$pids" ] && return 0
    log "stopping HelixScreen (pid $(echo $pids))"
    kill $pids 2>/dev/null
    # wait for these processes only (a new one may be starting meanwhile)
    i=0
    while [ $i -lt 20 ]; do
        alive=""
        for p in $pids; do [ -d /proc/$p ] && alive="$alive $p"; done
        [ -z "$alive" ] && return 0
        sleep 0.5; i=$((i + 1))
    done
    kill -9 $alive 2>/dev/null
    return 0
}

# start the stock screen exactly as Tina's /etc/init.d/rcS does
start_stock() {
    [ -n "$(stock_pids)" ] && return 0
    echo 1 > "$GPIO" 2>/dev/null
    if [ -n "${STOCK_CMD:-}" ]; then           # tests only
        $STOCK_CMD > /dev/null 2>&1 < /dev/null &
    else
        chroot /proc/1/root /bin/sh -c \
            "sed -n '/export TSLIB_ROOT/,/nohup \/opt\/FdmPrinter/p' /etc/init.d/rcS > /tmp/fdm_start.sh && sh /tmp/fdm_start.sh" \
            > /dev/null 2>&1 < /dev/null &
    fi
    log "stock screen started"
}

# HelixScreen up to v1.0.x ships a separate fbdev program (helix-screen-fbdev);
# from v1.1.0 one program (helix-screen) does fbdev with
# HELIX_DISPLAY_BACKEND=fbdev. Use whichever this release has.
pick_bin() {
    if [ -x "$APP/bin/helix-screen-fbdev" ]; then BIN=helix-screen-fbdev
    elif [ -x "$APP/bin/helix-screen" ]; then BIN=helix-screen
    else return 1; fi
}

app_version() {
    sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$APP/release_info.json" 2>/dev/null
}

# true when a release is unpacked completely: binary and release_info.json
# present and the binary's size the same twice, 2 s apart
install_stable() {
    local a b
    pick_bin && [ -f "$APP/release_info.json" ] || return 1
    a=$(stat -c %s "$APP/bin/$BIN" 2>/dev/null) || return 1
    sleep 2
    b=$(stat -c %s "$APP/bin/$BIN" 2>/dev/null) || return 1
    [ "$a" = "$b" ] && [ "$a" -gt 0 ]
}

wait_install() {   # <seconds>
    local end=$((SECONDS + $1))
    while [ $SECONDS -lt $end ]; do
        install_stable && return 0
        sleep 1
    done
    return 1
}

# Keep the user's files in $PDH and link them into $APP/config/.
# A real file or folder found in $APP/config/ is either moved to $PDH (first
# time) or, when $PDH already has it (a fresh release after an update), kept
# as <name>.shipped; for folders, entries $PDH lacks are copied over first.
link_user_config() {
    local c=$APP/config n f d
    [ -d "$c" ] || return 0
    mkdir -p "$PDH" || return 1
    for n in $USER_FILES $USER_DIRS; do
        f=$c/$n
        d=$PDH/$n
        [ -L "$f" ] && [ "$(readlink "$f")" = "$d" ] && continue
        if [ -e "$f" ] && [ ! -L "$f" ]; then
            if [ ! -e "$d" ]; then
                mv "$f" "$d" && log "config: moved $n to $PDH"
            else
                if [ -d "$f" ]; then
                    cp -an "$f/." "$d/" 2>/dev/null
                fi
                mv -T "$f" "$f.shipped.$(date +%s)" && log "config: kept the release's $n as $n.shipped.*"
            fi
        fi
        [ -e "$d" ] || continue
        if [ -L "$f" ]; then
            rm -f "$f"                   # a link pointing elsewhere
        elif [ -e "$f" ]; then
            log "config: $f could not be moved aside - not linked"
            continue
        fi
        ln -s "$d" "$f" && log "config: $n -> $d"
    done
    return 0
}

# While HelixScreen (pid $1) runs: when release_info.json shows a new version
# and the release is unpacked completely, wait a little and stop HelixScreen,
# so the main loop starts the new version (not counted as a failure).
watch_update() {
    local hpid=$1 v0 v
    v0=$(app_version)
    while kill -0 "$hpid" 2>/dev/null; do
        sleep "$UPDATE_POLL"
        v=$(app_version)
        [ -n "$v" ] && [ "$v" != "$v0" ] || continue
        install_stable || continue
        sleep 10
        install_stable || continue
        log "update: release_info.json changed from $v0 to $v - restarting HelixScreen"
        echo "$v" > "$RUN/update_restart"
        stop_helix
        return 0
    done
}

mode=${1:-now}
mkdir -p "$RUN" "$LOGDIR"
if [ "$mode" = stock ]; then
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null
        rm -f "$PIDFILE"
    fi
    stop_helix
    start_stock
    exit 0
fi
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "$mode: already running (pid $(cat "$PIDFILE")) - nothing to do"
    exit 0
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

if ! pick_bin; then
    log "$mode: no HelixScreen program in $APP/bin - keeping the stock screen"
    start_stock
    exit 1
fi

if [ "$mode" = boot ]; then
    # Tina starts the stock screen itself; wait for it so it cannot start
    # after HelixScreen and fight over the display
    i=0
    while [ -z "$(stock_pids)" ] && [ $i -lt $((WAIT_STOCK * 2)) ]; do
        sleep 0.5; i=$((i + 1))
    done
    if [ -z "$(stock_pids)" ]; then
        log "boot: stock screen did not appear within $WAIT_STOCK s"
    else
        sleep ${SETTLE:-5}      # let it finish starting before it is stopped
    fi
fi
stop_stock
stop_splash
stop_helix      # e.g. one started by hand with helix_try.sh

if [ "$mode" = boot ]; then
    # in case Tina starts it again a little later
    ( end=$((SECONDS + WATCH_STOCK))
      while [ $SECONDS -lt $end ]; do
          # stop watching if screen.sh switched back to the stock screen
          [ "$(cat "$CONF" 2>/dev/null)" = helix ] || exit 0
          [ "$(cat "$PIDFILE" 2>/dev/null)" = $$ ] || exit 0
          [ -n "$(stock_pids)" ] && { log "stock screen appeared again"; stop_stock; }
          sleep 2
      done ) &
fi

fails=()
while :; do
    if ! install_stable; then
        log "waiting for a complete HelixScreen install in $APP (update running?)"
        if ! wait_install 180; then
            log "no complete HelixScreen install after 180 s - back to the stock screen"
            start_stock
            exit 1
        fi
    fi
    # HelixScreen restarts itself when it sees an update (it relaunches the
    # new program, outside this script); such a copy holds HelixScreen's lock
    # (config/.helix-screen.lock), so stop any copy this script did not start
    if [ -n "$(helix_pids)" ]; then
        log "a HelixScreen not started by this script is running (pid $(helix_pids | xargs)) - stopping it"
        stop_helix
    fi
    link_user_config || log "config: could not create $PDH"
    rm -f "$RUN/update_restart"
    [ -f "$HLOG" ] && mv -f "$HLOG" "$HLOG.1"
    echo 1 > "$GPIO" 2>/dev/null           # backlight on
    pick_bin
    log "$mode: starting HelixScreen $(app_version) ($BIN)"
    started=$SECONDS
    ( cd "$APP" && exec env \
        HELIX_DISPLAY_BACKEND=fbdev \
        HELIX_BACKLIGHT_DEVICE=brightness \
        HELIX_DISPLAY_ROTATION=180 \
        HELIX_TOUCH_DEVICE=/dev/input/event0 \
        HELIX_TOUCH_MIN_X=0 HELIX_TOUCH_MAX_X=479 \
        HELIX_TOUCH_MIN_Y=0 HELIX_TOUCH_MAX_Y=271 \
        HELIX_DISABLE_AUTO_UPDATES=1 \
        nice -n 5 "./bin/$BIN" --log-dest=console --log-level=info \
        >> "$HLOG" 2>&1 < /dev/null ) &
    hpid=$!
    watch_update "$hpid" &
    wpid=$!
    wait "$hpid"
    rc=$?
    kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
    log "HelixScreen stopped (exit code $rc after $((SECONDS - started)) s)"
    # a newer copy of this script (screen.sh stock / helix) takes over
    [ "$(cat "$PIDFILE" 2>/dev/null)" = $$ ] || exit 0
    if [ -f "$RUN/update_restart" ]; then
        log "update: starting the new version"
        continue
    fi
    if [ "$(cat "$CONF" 2>/dev/null)" != helix ]; then
        log "screen.conf is no longer helix - starting the stock screen"
        start_stock
        exit 0
    fi
    now=$SECONDS
    keep=()
    for t in "${fails[@]}" "$now"; do
        [ $((now - t)) -lt $FAIL_WINDOW ] && keep+=("$t")
    done
    fails=("${keep[@]}")
    if [ ${#fails[@]} -ge $MAX_FAILS ]; then
        log "HelixScreen stopped $MAX_FAILS times within $FAIL_WINDOW s - back to the stock screen"
        start_stock
        exit 1
    fi
    sleep 2
done
