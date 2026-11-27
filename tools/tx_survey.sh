#!/bin/sh
# tx_survey.sh - read-only survey of an Infimech TX / FlyingBear S1 (V2 board)
# for the prebuilt Debian 12 image: which Tina Linux and kernel the printer
# runs, and what Tina's boot needs from /server. Changes nothing.
#
#   ssh root@<PRINTER_IP> "sh -s" < tx_survey.sh > tx_survey.txt 2>&1
#
# (Windows: run that line in cmd, not PowerShell.) Takes about a minute.
# The output is meant to be shared: IP and MAC addresses, the MCU chip id,
# serial numbers, the host name and Wi-Fi lines are masked or left out.
# Please read it before you post it anyway.
LC_ALL=C
export LC_ALL
S=/server
L=$S/tmp
sec() { echo; echo "===== $*"; }
have() { command -v "$1" > /dev/null 2>&1; }
# privacy filter for everything printed
mask() {
    grep -v -i -E 'ssid|psk|passw|secret|token|api_?key' |
    sed -E \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<IP>/g' \
        -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<MAC>/g' \
        -e 's/(stm32f072xb_)[0-9A-Fa-f]+/\1<chip id>/g' \
        -e 's/([Ss][Ee][Rr][Ii][Aa][Ll]([Nn][Oo])?[=:[:space:]]+)[0-9A-Za-z]{6,}/\1<serial>/g'
}
md5() { [ -f "$1" ] && md5sum "$1" 2>/dev/null | cut -c1-32 || echo "-"; }
# fingerprint of a folder tree: number of files and one md5 over all file md5s
tree_hash() {
    d=$1; shift
    [ -d "$d" ] || { echo "$d: missing"; return; }
    find "$d/" -xdev -type f "$@" 2>/dev/null | sort > /tmp/.txs_list
    n=$(wc -l < /tmp/.txs_list)
    h=$(while read -r f; do md5sum "$f" 2>/dev/null; done < /tmp/.txs_list | md5sum | cut -c1-32)
    echo "$d: $n files, $h"
    rm -f /tmp/.txs_list
}

echo "tx_survey v3  $(date -u +%Y-%m-%dT%H:%MZ)"

{
sec "1. Kernel and Tina"
echo "uname: $(uname -s -r -v -m)"
echo "proc/version: $(cut -d' ' -f1-3 /proc/version)"
for f in /etc/openwrt_release /etc/openwrt_version /etc/os-release /etc/tina_version /etc/version /etc/issue; do
    [ -f "$f" ] && { echo "--- $f"; head -n 12 "$f"; }
done
echo "busybox: $(busybox 2>&1 | head -n 1)"
echo "libc: $(ls /lib/libc-* /lib/libc.so* 2>/dev/null | tr '\n' ' ')"
echo "cmdline: $(tr ' ' '\n' < /proc/cmdline | grep -v -i -E 'serial|mac|uuid|sn=|chipid' | tr '\n' ' ')"
grep -E '^(Hardware|Revision|model name|Processor|CPU part)' /proc/cpuinfo | sort -u
grep MemTotal /proc/meminfo

sec "2. Storage"
echo "--- partitions (name from the kernel command line, device, size in kB)"
# Tina has no /dev/by-name: the names come from partitions= on the command line
tr ' ' '\n' < /proc/cmdline | sed -n 's/^partitions=//p' | tr ':' '\n' > /tmp/.txs_parts
n=0
while IFS=@ read -r name dev; do
    n=$((n+1))
    [ -n "$dev" ] || dev=mmcblk0p$n
    echo "$name $dev $(awk -v d="$dev" '$4==d {print $3}' /proc/partitions)"
done < /tmp/.txs_parts
awk '$4 ~ /^mmcblk0(boot[01])?$/ {print $4, $3}' /proc/partitions
echo "--- md5 of the small boot partitions (same vendor firmware = same values)"
while IFS=@ read -r name dev; do
    case "$name" in boot-resource|boot|dtb)
        [ -b "/dev/$dev" ] && echo "$name ($dev): $(md5sum "/dev/$dev" | cut -c1-32)" ;;
    esac
done < /tmp/.txs_parts
rm -f /tmp/.txs_parts
echo "--- mounts"
grep -E ' / | /server' /proc/mounts | awk '{print $2, $3, $4}' | cut -c1-80 | sort -u
df -k / $S 2>/dev/null | awk 'NR>1 {print $6": "$2" kB total, "$4" kB free"}'

sec "3. Tina file fingerprints (compare between printers)"
tree_hash /etc/init.d
tree_hash /etc/config
tree_hash /etc ! -path '/etc/init.d/*' ! -path '/etc/config/*' ! -name 'shadow*' ! -name 'passwd*' ! -name 'wpa_supplicant*' ! -name 'hostname' ! -name '*dropbear*' ! -name 'ssh_host*'
tree_hash /bin
tree_hash /sbin
tree_hash /lib
tree_hash /usr
tree_hash /opt
echo "--- single files"
for f in /etc/inittab /etc/init.d/rcS /etc/init.d/MountServer /etc/init.d/remote_update /etc/init.d/Network_select /etc/init.d/show_start.sh /etc/init.d/S100ki /opt/FdmPrinter /opt/profile.ini; do
    echo "$f: $(md5 "$f")"
done
find / -xdev -name 'Kilpper_check.sh' 2>/dev/null | while read -r f; do echo "$f: $(md5 "$f")"; done

sec "4. Boot chain: Tina lines that use /server"
for f in /etc/inittab /etc/init.d/* /etc/rc.local /etc/profile; do
    [ -f "$f" ] || continue
    grep -n '/server' "$f" 2>/dev/null | sed "s#^#$(basename "$f"):#"
done | cut -c1-200

sec "5. Boot chain: files Tina runs in /server"
for f in $L/go.sh $L/init-service.sh $L/run.sh $L/shutdown.sh $L/kamp_init.sh $L/updatestm32 \
         $L/home/gem/kp.sh $L/home/gem/kp.sh.stock $L/home/gem/local_mcu.sh $L/home/gem/local_mcu.sh.stock \
         $L/home/gem/moon.sh; do
    if [ -e "$f" ]; then echo "${f#$S}: present, md5 $(md5 "$f")"; else echo "${f#$S}: missing"; fi
done
for f in $L/go.sh $L/init-service.sh $L/run.sh; do
    [ -f "$f" ] || continue
    echo "--- ${f#$S} (commands, without comments)"
    grep -v -E '^\s*(#|$)' "$f" | cut -c1-160 | head -n 60
done

echo "--- vendor update package (remote_update installs it at boot if present)"
for f in $S/printer/zy3d_files.zip $S/printer/md5.txt; do
    if [ -e "$f" ]; then echo "${f}: PRESENT ($(wc -c < "$f") bytes)"; else echo "${f}: not present"; fi
done
[ -d $S/printer ] && echo "$S/printer: $(find $S/printer -type f 2>/dev/null | wc -l) files" || echo "$S/printer: no folder"

sec "6. The Debian system in /server/tmp"
echo "debian_version: $(cat $L/etc/debian_version 2>/dev/null || echo -)"
echo "glibc: $(ls $L/lib/arm-linux-gnueabihf/libc.so.6 $L/lib/arm-linux-gnueabihf/libc-* 2>/dev/null | tr '\n' ' ')"
for d in $S/*/; do
    [ -f "$d/etc/debian_version" ] && echo "system folder: ${d%/} (Debian $(cat "$d/etc/debian_version"))"
done
C=$L/home/gem/printer_data
for d in config config_stock config_new; do
    [ -e "$C/$d" ] || continue
    t=dir; [ -L "$C/$d" ] && t="link -> $(readlink "$C/$d")"
    echo "printer_data/$d: $t; printer_config.cfg: $(head -n 1 "$C/$d/printer_config.cfg" 2>/dev/null); printer.cfg: $(head -n 1 "$C/$d/printer.cfg" 2>/dev/null)"
done
for k in klipper klipper-new moonraker; do
    g=$L/home/gem/$k
    [ -d "$g" ] || continue
    if [ -d "$g/.git" ]; then
        v=$(chroot $L git -c safe.directory='*' -C /home/gem/$k describe --tags --always 2>/dev/null)
    else
        v="(no git)"
    fi
    echo "$k: ${v:--}"
done
[ -f $L/home/gem/helixscreen/release_info.json ] && echo "helixscreen: $(grep -o '"version"[^,]*' $L/home/gem/helixscreen/release_info.json)"
n=0; for p in /proc/[0-9]*; do [ "$(readlink "$p/root" 2>/dev/null)" = "$L" ] && n=$((n+1)); done
echo "processes running inside /server/tmp: $n"

sec "7. Hardware"
echo "fb0: $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null) $(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null) bpp"
grep '^N: Name=' /proc/bus/input/devices 2>/dev/null
echo "--- I2C devices"
for d in /sys/bus/i2c/devices/*-*; do
    [ -e "$d/name" ] && echo "$(basename "$d"): $(cat "$d/name")"
done
echo "--- USB devices (vendor:product, name)"
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct") $(cat "$d/product" 2>/dev/null)"
done | sort -u
echo "--- GPIO chips (base, count)"
for g in /sys/class/gpio/gpiochip*; do
    [ -e "$g/base" ] && echo "$(basename "$g"): $(cat "$g/base") $(cat "$g/ngpio") $(cat "$g/label" 2>/dev/null)"
done
for n in 142 143 228 232 256; do
    [ -d /sys/class/gpio/gpio$n ] && echo "gpio$n exported: direction $(cat /sys/class/gpio/gpio$n/direction) value $(cat /sys/class/gpio/gpio$n/value)"
done

sec "8. Vendor update servers (DNS)"
for h in update.octopusworks.com slice-update.octopusworks.com; do
    r=$(nslookup "$h" 2>/dev/null | awk '/^Address/ && !/#53/ {print $NF}' | tail -n 1)
    case "$r" in
        "") k="does not resolve" ;;
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|0.0.0.0) k="resolves to a local address (blocked)" ;;
        *) k="resolves to a public address (NOT blocked)" ;;
    esac
    echo "$h: $k"
done
} 2>&1 | mask

echo
echo "===== end of survey"
