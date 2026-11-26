#!/bin/sh
# Read-only check after the switch to Debian 12 (run a minute or two after
# the power cycle, when the screen is up):
#   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_after.sh > ~/fw/steps/5_debian12/deb12_after.txt 2>&1
L=/server/tmp
G=/home/gem
LOGS=$L$G/printer_data/logs
echo "== systems"
echo "/server/tmp:       Debian $(cat $L/etc/debian_version) $(cat $L/.switched-to-debian12 2>/dev/null)"
echo "/server/tmp_deb11: Debian $(cat /server/tmp_deb11/etc/debian_version 2>/dev/null)"
df -h /server | tail -n 1
echo "== services"
chroot $L /usr/local/bin/supervisorctl status < /dev/null | tr -s ' '
for n in kp.sh moon.sh local_mcu.sh svc_loop.sh helix-screen FdmPrinter nginx; do
    c=0; for p in /proc/[0-9]*; do tr '\0' ' ' < $p/cmdline 2>/dev/null | grep -q "$n" && c=$((c + 1)); done
    echo "  $n: $c process(es)"
done
echo "== Moonraker and Klipper"
chroot $L python3 - 2>&1 <<'EOF'
import json, urllib.request
def res(p):
    try:
        return json.load(urllib.request.urlopen("http://127.0.0.1:7125" + p, timeout=15))["result"]
    except Exception as e:
        return {"error": str(e)}
i = res("/server/info")
print("moonraker:", i.get("moonraker_version"), "| klippy:", i.get("klippy_state"), "| failed components:", i.get("failed_components"))
for w in i.get("warnings", []) or []:
    print("  warning:", w)
p = res("/printer/info")
print("klipper:", p.get("software_version"), "|", p.get("state"), "|", (p.get("state_message") or "").splitlines()[0:1])
t = res("/server/history/totals").get("job_totals", {})
print("history jobs:", t.get("total_jobs"))
s = res("/machine/system_info").get("system_info", {})
print("services:", {k: v.get("active_state") for k, v in (s.get("service_state") or {}).items()})
u = res("/machine/update/status")
for n, v in (u.get("version_info") or {}).items():
    if n == "system":
        print(f"  update system: {v.get('package_count')} packages")
    else:
        print(f"  update {n}: {v.get('version')} -> {v.get('remote_version')} valid={v.get('is_valid')} dirty={v.get('is_dirty')} channel={v.get('channel')}")
EOF
echo "== logs"
echo "-- boot_select.log"; tail -n 3 $LOGS/boot_select.log 2>/dev/null
echo "-- services.log"; tail -n 8 $LOGS/services.log 2>/dev/null
echo "-- screen.log"; tail -n 4 $LOGS/screen.log 2>/dev/null
echo "-- moonraker.log (warnings/errors)"; grep -i -E 'warning|error|exception|migrat' $LOGS/moonraker.log 2>/dev/null | cut -c1-200 | tail -n 12
echo "-- klippy.log (errors)"; grep -E '^(Config error|Error|Traceback|MCU .* shutdown)|Unhandled' $LOGS/klippy.log 2>/dev/null | tail -n 8
echo "== end"
