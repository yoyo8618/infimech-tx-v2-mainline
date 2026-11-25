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
BIN=helix-screen-fbdev
WAIT_STOCK=${WAIT_STOCK:-90}        # boot: seconds to wait for the stock screen
WATCH_STOCK=${WATCH_STOCK:-120}     # boot: keep stopping it for this long
MAX_FAILS=3
FAIL_WINDOW=300

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

# HelixScreen's process name is cut to 15 characters
helix_pids() {
    local p
    for p in /proc/[0-9]*; do
        [ "$(cat "$p/comm" 2>/dev/null)" = helix-screen-fb ] && echo "${p#/proc/}"
    done
}

stop_helix() {
    local pids i p alive
    pids=$(helix_pids)
    [ -z "$pids" ] && return 0
    log "stopping HelixScreen (pid $pids)"
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

if [ ! -x "$APP/bin/$BIN" ]; then
    log "$mode: $APP/bin/$BIN not found - keeping the stock screen"
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
    [ -f "$HLOG" ] && mv -f "$HLOG" "$HLOG.1"
    echo 1 > "$GPIO" 2>/dev/null           # backlight on
    log "$mode: starting HelixScreen"
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
        >> "$HLOG" 2>&1 < /dev/null )
    rc=$?
    log "HelixScreen stopped (exit code $rc after $((SECONDS - started)) s)"
    # a newer copy of this script (screen.sh stock / helix) takes over
    [ "$(cat "$PIDFILE" 2>/dev/null)" = $$ ] || exit 0
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
