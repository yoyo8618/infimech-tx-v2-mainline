#!/bin/bash
# Keeps one service running. Started by /run.sh in a tmux pane, as root:
#   svc_loop.sh <name> <command...>
# The command is started again 2 s after it ends, unless it was stopped
# with "supervisorctl stop <name>" (flag in /run/infimech, gone at power-off).
name=$1; shift
FLAGS=/run/infimech
LOG=/home/gem/printer_data/logs/services.log
mkdir -p "$FLAGS"
while :; do
    if [ -f "$FLAGS/stop_$name" ]; then sleep 1; continue; fi
    [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1000000 ] && mv -f "$LOG" "$LOG.1"
    echo "$(date '+%F %T') $name: starting" >> "$LOG"
    "$@"
    echo "$(date '+%F %T') $name: ended (exit code $?)" >> "$LOG"
    sleep 2
done
