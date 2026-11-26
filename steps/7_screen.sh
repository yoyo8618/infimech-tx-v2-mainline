#!/bin/bash
# Step 7: HelixScreen on the touchscreen in place of the stock screen.
# Needs step 4 (new Klipper at power-on). Works on Debian 11 and 12; the
# update-from-Fluidd entry is added when Moonraker v0.11 (step 5) is there.
#
# Run inside the Debian chroot as root, printer idle:
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/7_screen.sh --check"
#   ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/7_screen.sh" > step7.txt 2>&1
# HelixScreen comes from its GitHub release (helixscreen-pi32.zip, tested:
# v1.1.0). The script downloads it, or uses /home/gem/infimech/helixscreen-pi32.zip
# if you put one there. On first start HelixScreen runs its setup wizard on
# the touchscreen. If it says the printer "looks like a Sovol SV06 ACE",
# tap "Keep current".
# Back to the stock screen: chroot /server/tmp bash /home/gem/infimech/screen.sh stock
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
G=${G:-/home/gem}
F=$G/infimech/steps/files
APP=$G/helixscreen
ZIP=${HELIX_ZIP:-$G/infimech/helixscreen-pi32.zip}
HVER=${HELIX_VERSION:-v1.1.0}
URL=https://github.com/prestonbrown/helixscreen/releases/download/$HVER/helixscreen-pi32.zip
BRI=${BRI:-/usr/bin/brightness}
MCONF=$G/printer_data/config_new/infimech_moonraker.conf
MARK="Installed by /home/gem/infimech/boot_install.sh"
HOOK='helix_run.sh boot'
CHECK=0; NOSTART=0
for a in "$@"; do case "$a" in --check) CHECK=1 ;; --no-start) NOSTART=1 ;; esac; done
say() { echo; echo "$(date '+%H:%M:%S') === $*"; }
die() { echo "$(date '+%H:%M:%S') ERROR: $*"; echo "Nothing more was changed."; exit 1; }

say "Step 7: HelixScreen$([ $CHECK = 1 ] && echo ' - CHECK ONLY')"
[ "$(id -u)" = 0 ] || die "run as root inside the chroot"
grep -qs "$MARK" "$G/kp.sh" || die "step 4 is not installed (kp.sh)"
grep -qF "$HOOK" "$G/kp.sh" || die "$G/kp.sh has no HelixScreen line (it comes with step 4's kp.sh)"
for f in helix_run.sh screen.sh brightness; do bash -n "$F/$f" || die "syntax error in $F/$f"; done
grep -q '^manage_thresholds: auto' "$G/printer_data/config_new/infimech.cfg" \
    || die "manage_thresholds is not 'auto' in config_new/infimech.cfg (Klipper must set the bed sensor thresholds without the stock screen)"
[ -e "$BRI" ] && ! grep -q "Infimech TX V2 backlight helper" "$BRI" && die "$BRI exists and is not the Infimech backlight helper"
if [ -e "$APP" ]; then
    echo "HelixScreen already in $APP: $(cat "$APP/release_info.json" 2>/dev/null) - it is kept (update it from Fluidd)"
    INSTALL=0
else
    INSTALL=1
    if [ -f "$ZIP" ]; then echo "HelixScreen: $ZIP"; else echo "HelixScreen: will download $HVER ($URL)"; fi
fi
FREE=$(df -Pm "$G" | awk 'NR == 2 {print $4}')
[ "${FREE:-0}" -ge 300 ] || die "only ${FREE:-?} MB free"
if [ $CHECK = 1 ]; then say "CHECK PASSED - nothing was changed"; exit 0; fi

if [ $INSTALL = 1 ]; then
    say "1. HelixScreen into $APP"
    if [ ! -f "$ZIP" ]; then
        python3 -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" "$URL" "$ZIP.part" \
            && mv "$ZIP.part" "$ZIP" || die "download failed (internet?) - put helixscreen-pi32.zip in $G/infimech/ by hand"
    fi
    python3 - "$ZIP" "$APP.new" <<'EOF' || die "unpacking failed"
import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
assert "release_info.json" in z.namelist(), "not a HelixScreen release zip"
for i in z.infolist():
    p = z.extract(i, sys.argv[2])
    mode = (i.external_attr >> 16) & 0o777
    if mode and not i.is_dir():
        os.chmod(p, mode)
EOF
    mv -T "$APP.new" "$APP" || die "could not create $APP"
    echo "installed: $(cat "$APP/release_info.json")"
    B=$APP/bin/helix-screen-fbdev; [ -x "$B" ] || B=$APP/bin/helix-screen
    [ -x "$B" ] || die "no HelixScreen program in $APP/bin"
    missing=$(ldd "$B" 2>&1 | grep "not found" || true)
    [ -z "$missing" ] || die "HelixScreen is missing libraries: $missing"
fi

say "2. launcher, screen switch, backlight helper"
mkdir -p "$G/infimech/screen"
install -m 755 "$F/helix_run.sh" "$G/infimech/screen/helix_run.sh" || die "copy failed"
install -m 755 "$F/screen.sh" "$G/infimech/screen.sh" || die "copy failed"
install -m 755 "$F/brightness" "$BRI" || die "copy failed"
[ -f "$G/infimech/screen.conf" ] || echo stock > "$G/infimech/screen.conf"
echo "helix_run.sh, screen.sh, $BRI installed"

say "3. updates from Fluidd"
if [ -f "$MCONF" ]; then
    if grep -q '^\[update_manager helixscreen\]' "$MCONF"; then
        echo "already in $MCONF"
    else
        cp -p "$MCONF" "$MCONF.bak-step7"
        cat >> "$MCONF" <<'EOF'

# HelixScreen (touchscreen). Moonraker replaces /home/gem/helixscreen with
# the new release; the user's files stay in printer_data/config/helixscreen
# (linked by infimech/screen/helix_run.sh, which also restarts HelixScreen
# once the new release is unpacked).
[update_manager helixscreen]
type: web
channel: stable
repo: prestonbrown/helixscreen
path: /home/gem/helixscreen
EOF
        echo "[update_manager helixscreen] added - takes effect when Moonraker restarts"
        command -v supervisorctl > /dev/null && supervisorctl restart moonraker > /dev/null 2>&1 && echo "Moonraker restarted"
    fi
else
    echo "no Moonraker v0.11 yet (step 5) - HelixScreen updates from Fluidd come with step 5 + running this again"
fi

if [ $NOSTART = 1 ]; then
    say "DONE - start it with: chroot /server/tmp bash $G/infimech/screen.sh helix"
    exit 0
fi
say "4. switching to HelixScreen (now and at every power-on)"
bash "$G/infimech/screen.sh" helix || die "screen.sh helix failed"
say "DONE - HelixScreen should be on the touchscreen. Back: screen.sh stock"
