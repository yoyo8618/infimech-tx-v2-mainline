#!/bin/bash
# Links Infimech's Klipper add-ons into the Klipper folder. Run by kp.sh at
# every start of the v0.14+ Klipper; safe to run by hand.
# The add-ons live in /home/gem/infimech/klippy_extras, so Klipper updates
# (or a fresh copy of Klipper) never lose them and git doesn't count them
# as changes.
G=${G:-/home/gem}
K=$G/klipper-new
SRC=$G/infimech/klippy_extras
[ -d "$K/klippy/extras" ] || exit 0
for f in "$SRC"/*.py; do
    [ -f "$f" ] || continue
    l=$K/klippy/extras/${f##*/}
    [ "$(readlink "$l")" = "$f" ] || ln -sfn "$f" "$l"
done
# older scripts look for the host MCU program in klipper-new/out-host
[ -e "$K/out-host" ] || ln -s "$G/klipper-host" "$K/out-host"
if [ -d "$K/.git" ]; then
    mkdir -p "$K/.git/info"
    for p in "/klippy/extras/infimech_*.py" "/out-host"; do
        grep -qxF "$p" "$K/.git/info/exclude" 2>/dev/null || echo "$p" >> "$K/.git/info/exclude"
    done
    # refresh git's saved file index, so Klipper's start-up check
    # ("git describe --dirty") compares current file details (version 2)
    git -C "$K" update-index -q --refresh > /dev/null 2>&1
fi
exit 0
