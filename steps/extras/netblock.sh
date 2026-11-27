#!/bin/sh
# Printer-side block of the vendor servers (update.octopusworks.com,
# slice-update.octopusworks.com and the stock screen's log server), as a
# second layer next to the router's DNS rewrite. Nothing on Tina changes:
# Debian 12's iptables (legacy) and Tina's own iptable_filter kernel module
# are used, and one line in /server/tmp/go.sh starts the block at boot.
# At every start it re-blocks the saved addresses and looks the two names
# up; any new public address is blocked and saved. Ping stays allowed
# (Tina's Network_select uses it). Local addresses are never blocked.
# Needs the Debian 12 system from step 5. Run from the folder with this file
# (cmd or Ubuntu window):
#   check (default, changes nothing):
#     ssh root@<PRINTER_IP> "sh -s" < netblock.sh > netblock_check.txt 2>&1
#   install (installs the iptables package in Debian 12; needs internet):
#     ssh root@<PRINTER_IP> "sh -s -- apply" < netblock.sh > netblock.txt 2>&1
#   status (rules, counters, log):
#     ssh root@<PRINTER_IP> "sh -s -- status" < netblock.sh > netblock_status.txt 2>&1
#   undo (removes the rules and the go.sh line; keeps the package and the address list):
#     ssh root@<PRINTER_IP> "sh -s -- undo" < netblock.sh > netblock_undo.txt 2>&1
# Tested on the author's printer: after "apply" both vendor addresses were
# refused and github.com connected; after a power-on the rules were back.
MODE=${1:-check}
L=/server/tmp
NB=$L/home/gem/infimech/netblock
GO=$L/go.sh
HOOK='[ -f /server/tmp/home/gem/infimech/netblock/netblock_boot.sh ] && sh /server/tmp/home/gem/infimech/netblock/netblock_boot.sh boot < /dev/null > /dev/null 2>&1 &   # infimech netblock'
IPT="chroot $L /usr/sbin/iptables-legacy -w"
# addresses known on 2026-11-27 (update.octopusworks.com = the log server)
SEEDS="120.77.245.96 119.23.245.194"
say() { echo; echo "$(date +%H:%M:%S) === $*"; }
note() { echo "  $*"; }
die() { echo "ERROR: $*"; exit 1; }
case "$MODE" in check|apply|status|undo) ;; *) die "use: check, apply, status or undo" ;; esac
[ "$(id -u)" = 0 ] || die "run as root"
grep -q '^12' $L/etc/debian_version 2>/dev/null || die "$L is not the Debian 12 system"
mkdir -p /tmp/netblock_inst
cat > /tmp/netblock_inst/netblock_boot.sh <<'NB_BOOT_EOF'
#!/bin/sh
# Printer-side block of the vendor servers for the Infimech TX.
# Started at boot from /server/tmp/go.sh (one line added by netblock.sh).
# Blocks TCP and UDP to every public address the vendor host names have
# resolved to (ping stays allowed: Tina's Network_select pings
# update.octopusworks.com to choose Ethernet or Wi-Fi). At boot it re-adds
# the saved addresses, then looks the names up every 30 s until they answer
# (at most 20 min) and then every 6 hours; a new public address is added and
# saved. Local addresses (your router's DNS rewrite) are never blocked.
#   sh netblock_boot.sh boot    start (background loop)
#   sh netblock_boot.sh once    set up the rules and look up once, then exit
NB=/server/tmp/home/gem/infimech/netblock
LOG=$NB/netblock.log
IPS=$NB/ips.txt
HOSTS="update.octopusworks.com slice-update.octopusworks.com"
IPT="chroot /server/tmp /usr/sbin/iptables-legacy -w"
PIDF=/run/netblock.pid
CHAIN=VENDOR_BLOCK
MAXIPS=64

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

is_public() {
    echo "$1" | awk -F. 'NF==4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; exit 0 } { exit 1 }' || return 1
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        22[4-9].*|2[3-5][0-9].*) return 1 ;;
    esac
    return 0
}

# IPv4 answers for a name (BusyBox nslookup: "Address: x" lines after "Name:")
resolve() {
    nslookup "$1" 2>/dev/null | awk '/^Name:/ {f = 1; next} f && /^Address/ {print $NF}' |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

setup() {
    [ -x /server/tmp/usr/sbin/iptables-legacy ] || { log "ERROR: iptables-legacy is not installed in /server/tmp"; return 1; }
    K=/lib/modules/$(uname -r)
    if ! grep -qx filter /proc/net/ip_tables_names 2>/dev/null; then
        m=$(find "$K" -name iptable_filter.ko 2>/dev/null | head -n 1)
        [ -n "$m" ] && insmod "$m" 2>> "$LOG"
    fi
    grep -qx filter /proc/net/ip_tables_names 2>/dev/null || { log "ERROR: no filter table (iptable_filter.ko)"; return 1; }
    if ! grep -q REJECT /proc/net/ip_tables_targets 2>/dev/null; then
        m=$(find "$K" -name ipt_REJECT.ko 2>/dev/null | head -n 1)
        [ -n "$m" ] && insmod "$m" 2> /dev/null
    fi
    if grep -q REJECT /proc/net/ip_tables_targets 2>/dev/null; then
        TCPT="REJECT --reject-with tcp-reset"
    else
        TCPT="DROP"
    fi
    $IPT -N $CHAIN 2> /dev/null
    $IPT -C OUTPUT -j $CHAIN 2> /dev/null || $IPT -I OUTPUT 1 -j $CHAIN || { log "ERROR: cannot add the OUTPUT rule"; return 1; }
    return 0
}

block() {   # block <ip>
    $IPT -C $CHAIN -d "$1" -p tcp -j $TCPT 2> /dev/null || $IPT -A $CHAIN -d "$1" -p tcp -j $TCPT
    $IPT -C $CHAIN -d "$1" -p udp -j DROP 2> /dev/null || $IPT -A $CHAIN -d "$1" -p udp -j DROP
}

saved() { grep -o -E '^[0-9.]+' "$IPS" 2>/dev/null; }

lookup() {  # returns 0 if both names answered
    ok=0
    for h in $HOSTS; do
        r=$(resolve "$h")
        [ -n "$r" ] && ok=$((ok + 1))
        for ip in $r; do
            is_public "$ip" || continue
            saved | grep -qx "$ip" && continue
            if [ "$(saved | wc -l)" -ge $MAXIPS ]; then
                log "limit of $MAXIPS addresses reached, $ip ($h) not added"
                continue
            fi
            echo "$ip  $h  $(date '+%Y-%m-%d')" >> "$IPS"
            block "$ip"
            log "new address for $h: $ip - blocked"
        done
    done
    [ $ok -eq 2 ]
}

start() {
    setup || exit 1
    n=0
    for ip in $(saved); do block "$ip"; n=$((n + 1)); done
    log "rules ready ($TCPT for TCP), $n saved addresses blocked"
}

case "$1" in
    boot)
        [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        if [ -f $PIDF ] && kill -0 "$(cat $PIDF)" 2> /dev/null; then
            log "already running (pid $(cat $PIDF))"
            exit 0
        fi
        echo $$ > $PIDF
        start
        tries=0
        while :; do
            if lookup || [ $tries -ge 40 ]; then
                sleep 21600
            else
                tries=$((tries + 1))
                sleep 30
            fi
        done
        ;;
    once)
        start
        lookup && log "lookup done" || log "lookup: a name did not answer"
        ;;
    *)
        echo "use: boot or once"
        exit 1
        ;;
esac
NB_BOOT_EOF
nbsh() { sh /tmp/netblock_inst/netblock_boot.sh "$@"; }
hooked() { grep -q 'infimech netblock' $GO 2>/dev/null; }
running() { [ -f /run/netblock.pid ] && kill -0 "$(cat /run/netblock.pid)" 2> /dev/null; }

if [ "$MODE" = status ]; then
    say "status"
    if hooked; then note "go.sh: starts the block at boot"; else note "go.sh: no netblock line"; fi
    if running; then note "background lookup: running (pid $(cat /run/netblock.pid))"; else note "background lookup: not running"; fi
    echo "--- rules (packets and bytes blocked so far)"
    $IPT -L VENDOR_BLOCK -n -v 2>&1
    $IPT -S OUTPUT 2>&1
    echo "--- blocked addresses ($NB/ips.txt)"
    cat $NB/ips.txt 2>/dev/null
    echo "--- log (last 20 lines)"
    tail -n 20 $NB/netblock.log 2>/dev/null
    exit 0
fi

if [ "$MODE" = undo ]; then
    say "undo"
    if running; then kill "$(cat /run/netblock.pid)" && note "background lookup stopped"; rm -f /run/netblock.pid; fi
    if [ -x $L/usr/sbin/iptables-legacy ]; then
        while $IPT -C OUTPUT -j VENDOR_BLOCK 2> /dev/null; do $IPT -D OUTPUT -j VENDOR_BLOCK; done
        $IPT -F VENDOR_BLOCK 2> /dev/null && $IPT -X VENDOR_BLOCK 2> /dev/null && note "rules removed"
    fi
    if hooked; then
        cp -p $GO $NB/go.sh.before-undo
        grep -v 'infimech netblock' $GO > $GO.new && cat $GO.new > $GO && rm -f $GO.new
        hooked && die "could not remove the go.sh line"
        note "go.sh line removed (copy before: $NB/go.sh.before-undo)"
    fi
    note "kept: the iptables package and $NB (address list, log)"
    say "DONE (undo)"
    exit 0
fi

say "1. checks ($MODE)"
K=/lib/modules/$(uname -r)
F=$(find "$K" -name iptable_filter.ko 2>/dev/null | head -n 1)
[ -n "$F" ] || grep -qx filter /proc/net/ip_tables_names || die "no iptable_filter.ko in $K - this kernel cannot filter"
note "filter module: ${F:-already loaded}"
grep -qx filter /proc/net/ip_tables_names || command -v insmod > /dev/null 2>&1 || die "no insmod on Tina - cannot load the filter module"
R=$(find "$K" -name ipt_REJECT.ko 2>/dev/null | head -n 1)
note "REJECT module: ${R:-not found (TCP is dropped instead of refused)}"
[ "$(grep -c 'rm -rf $DIR/tmp/\*' $GO)" = 1 ] || die "go.sh does not look as expected (line 'rm -rf \$DIR/tmp/*' not found once)"
if hooked; then note "go.sh: netblock line already there"; else note "go.sh: the netblock line will go after 'rm -rf \$DIR/tmp/*'"; fi
if [ -x $L/usr/sbin/iptables-legacy ]; then
    note "iptables: installed ($(chroot $L /usr/sbin/iptables-legacy -V 2>&1))"
else
    note "iptables: not installed; apt would install:"
    chroot $L apt-get install -s --no-install-recommends iptables 2>&1 | grep -E '^Inst|^E:' | sed 's/^/    /'
fi
echo "--- addresses that would be blocked"
for ip in $SEEDS $(cat $NB/ips.txt 2>/dev/null | grep -o -E '^[0-9.]+'); do echo "$ip"; done | sort -u | sed 's/^/    saved: /'
for h in update.octopusworks.com slice-update.octopusworks.com; do
    for ip in $(nslookup "$h" 2>/dev/null | awk '/^Name:/ {f = 1; next} f && /^Address/ {print $NF}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'); do
        case "$ip" in 0.*|10.*|127.*|169.254.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) echo "    $h now: $ip (local or blocked by DNS - not added)" ;;
            *) echo "    $h now: $ip (public - blocked)" ;; esac
    done
done
if [ "$MODE" = check ]; then
    say "CHECK ONLY - nothing changed. To install: sh -s -- apply"
    exit 0
fi

say "2. iptables in Debian 12"
if [ ! -x $L/usr/sbin/iptables-legacy ]; then
    chroot $L apt-get update -q 2>&1 | tail -n 3
    chroot $L env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends iptables 2>&1 | tail -n 5
    [ -x $L/usr/sbin/iptables-legacy ] || die "iptables did not install - nothing else changed"
fi
note "$(chroot $L /usr/sbin/iptables-legacy -V 2>&1)"

say "3. block script and address list"
mkdir -p $NB || die "cannot create $NB"
cp /tmp/netblock_inst/netblock_boot.sh $NB/netblock_boot.sh
for ip in $SEEDS; do
    grep -q "^$ip " $NB/ips.txt 2>/dev/null || echo "$ip  known address  $(date +%Y-%m-%d)" >> $NB/ips.txt
done
note "$NB/netblock_boot.sh, $NB/ips.txt ($(grep -c . $NB/ips.txt) addresses)"

say "4. rules now"
if running; then kill "$(cat /run/netblock.pid)"; rm -f /run/netblock.pid; fi
sh $NB/netblock_boot.sh once || die "setting up the rules failed - see $NB/netblock.log"
tail -n 3 $NB/netblock.log | sed 's/^/  /'
$IPT -S VENDOR_BLOCK | sed 's/^/  /'

say "5. start at boot (go.sh)"
if ! hooked; then
    cp -p $GO $NB/go.sh.before-netblock
    awk -v hook="$HOOK" '{print; l = $0; sub(/[ \t\r]+$/, "", l); sub(/^[ \t]+/, "", l)} l == "rm -rf $DIR/tmp/*" && !done {print hook; done = 1}' $GO > $GO.new || die "editing go.sh failed"
    grep -q 'infimech netblock' $GO.new || { rm -f $GO.new; die "editing go.sh failed - go.sh unchanged"; }
    cat $GO.new > $GO && rm -f $GO.new
    note "line added (backup: $NB/go.sh.before-netblock)"
fi
grep -n -A1 'rm -rf \$DIR/tmp/\*' $GO | sed 's/^/  /'
if command -v setsid > /dev/null 2>&1; then
    setsid sh $NB/netblock_boot.sh boot < /dev/null > /dev/null 2>&1 &
else
    nohup sh $NB/netblock_boot.sh boot < /dev/null > /dev/null 2>&1 &
fi
sleep 2
running && note "background lookup started (pid $(cat /run/netblock.pid))"

say "6. test"
chroot $L python3 - <<'PY_EOF'
import socket
def try_connect(host, port):
    try:
        s = socket.create_connection((host, port), timeout=5)
        s.close()
        return "connected"
    except ConnectionRefusedError:
        return "refused"
    except socket.timeout:
        return "timed out"
    except OSError as e:
        return "error: %s" % e.strerror
for ip in open("/home/gem/infimech/netblock/ips.txt").read().split("\n"):
    ip = ip.split(" ")[0]
    if ip:
        print("  vendor %-15s port 443: %s (should be refused or timed out)" % (ip, try_connect(ip, 443)))
print("  github.com          port 443: %s (should be connected)" % try_connect("github.com", 443))
PY_EOF
say "DONE. Status any time: sh -s -- status"
