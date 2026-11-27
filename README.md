# Infimech TX V2 → mainline Klipper, Debian 12, updates from Fluidd

**Status:** working on one printer (mine) since Nov 2026, with prints running normally. This describes what was done. The scripts for each step are in [`steps/`](steps/README.md); it's not a one-click installer. **Feedback wanted**: open an Issue.

> **How this was made:** the scripts, add-on modules and config changes were written with an AI assistant (Claude). I ran and checked every step on my own TX V2. Read the scripts before you run them, run the `--check` modes first, and **make the backup in step 1**.

**What you end up with**
- Mainline Klipper v0.14.0: host, STM32 mainboard firmware and the host MCU (`rpi`)
- Moonraker v0.11, Fluidd v1.38, HelixScreen on the touchscreen
- Debian 12 with security updates, and Klipper/Moonraker/Fluidd updates, all from Fluidd's update manager
- A tested way to rebuild and flash the firmware after each Klipper update
- The stock screen stays as an automatic fallback, and every step can be undone

**What stays vendor:** Tina Linux and its 4.9 kernel. No mainline kernel supports the V853's display and Wi-Fi yet. Debian runs in Tina's chroot at `/server/tmp`, as on stock.

**How to use this guide:** do steps 1 and 2 below by hand. Then do steps 3–7 with the scripts, following **[`steps/README.md`](steps/README.md)**. Do step 8 after every Klipper update. Sections 3–7 below explain what the scripts do and why; you don't type those parts yourself.

**You need:** root SSH to the printer, a Windows PC with WSL (Ubuntu 24.04), and patience. Use **cmd, not PowerShell**, for `ssh ... < file` and `> file`. **Power-cycle with the button, never `reboot`**: a soft reboot can leave the board black.

---

## 1. Back up everything first

In cmd, in an empty folder:
```
ssh root@<PRINTER_IP> "dd if=/dev/mmcblk0p1 bs=64k" > p1.img
```
Repeat for `p2` … `p5`, `mmcblk0boot0` and `mmcblk0boot1` (or run `scripts/backup.bat`, which does all of it). Then:
```
ssh root@<PRINTER_IP> "tar -C /server --exclude=./tmp/proc --exclude=./tmp/sys --exclude=./tmp/dev --exclude=./tmp/run -cf - ." > server.tar
```
Compare `md5sum` on the printer with `certutil -hashfile <file> MD5` on the PC.

## 2. Block vendor updates (do this first)

**A vendor (Infimech/OctopusWorks) firmware update can undo all of this.** Tina installs it at boot with `/etc/init.d/remote_update`, whenever `/server/printer/zy3d_files.zip` exists (the stock screen downloads it there). The log it left on the author's printer from an earlier update shows what it does: it copies the package's `/etc`, `/opt` and `/server` over the system (Tina's start scripts, the stock screen, and the Klipper setup in `/server/tmp`), then writes the boot partitions with `dd`. The STM32 also gets the stock firmware again when the `updatestm32` marker is missing. Your backup from step 1 would get you back, but it's easier not to let one in.

What's known about the stock software:
- The update client is in the stock touchscreen app (`/opt/FdmPrinter`), which talks to `slice-update.octopusworks.com`. Whether it ever installs without asking is unknown, so treat it as if it could.
- Tina's `Network_select` checks every 5 s. Only while an Ethernet cable is connected does it ping `update.octopusworks.com` (first over Ethernet, then over Wi-Fi) to choose the default route; with Wi-Fi only it always uses Wi-Fi.
- The stock screen also has a raw address for uploading logs: `120.77.245.96:8084/printer/log/upload`. A DNS rule can't block a raw address.

What to do:
1. In your DNS (AdGuard Home, Pi-hole, router), add a rewrite for `*.octopusworks.com` pointing to **any local IP that answers ping** (another device on your network). If you use an Ethernet cable, don't make the name fail outright: when both pings fail, `Network_select` swaps the default route between Ethernet and Wi-Fi every few seconds. Make sure **every** DNS server your router hands out has the rule; with a second server without it, the printer sometimes gets the real address.
2. Block the vendor addresses on the printer itself, after step 5 (Debian 12): [`steps/extras/netblock.sh`](steps/extras/netblock.sh) installs Debian's `iptables`, loads Tina's own `iptable_filter` module at boot (one line in `/server/tmp/go.sh`; Tina's files don't change) and refuses TCP / drops UDP to `120.77.245.96` (also the log server) and `119.23.245.194`. At every boot and every 6 hours it looks both names up again and blocks any new public address. Ping stays allowed. `check`, `apply`, `status` and `undo` modes; see the comments at the top. Or block those addresses in your router's firewall.
3. Before converting, check that `/server/printer/zy3d_files.zip` does not exist (`tools/tx_survey.sh` reports it).
4. Never accept an update offered on the stock screen. With HelixScreen installed, the stock screen only comes back as a fallback.

After the conversion, mainline updates come only from Fluidd (Settings → Software Updates). Nothing updates by itself: Moonraker's automatic refresh is off, and HelixScreen's own updater is disabled.

## 3. Mainline Klipper next to stock

> Sections 3–7 explain what the step scripts do. To run them, follow [`steps/README.md`](steps/README.md).


- Install Klipper v0.14.0 in `/home/gem/klipper-new` and build the host MCU on the printer (`CONFIG_MACH_LINUX=y`).
- Copy the vendor config to `config_new` and edit only the copy:
  - Remove `position_endstop: 0` from `[stepper_z]`. v0.14 rejects it with a probe endstop.
  - Set `min_temp: 0` instead of `-200` on the extruder and bed.
  - Replace the vendor's KAMP mesh macro with Klipper's own `BED_MESH_CALIBRATE ADAPTIVE=1`. The vendor macro runs `SAVE_CONFIG` after every mesh. Vendor Klipper saves without restarting; mainline restarts, which loses homing mid-print.
  - **Keep the `SET_TMC_CURRENT` calls before X/Y homing.** They look redundant, but without them sensorless homing stops short.
- A ready config is in `config/`. Check it offline before touching hardware:
  `klippy.py printer.cfg -i test.gcode -o out -d stm32.dict -d rpi=host.dict -l check.log`
- The bed sensor (I2C bus 2, 0x40) and a few vendor behaviours (probe retry, `STEPPER_BUZZ_TEST`) need small add-on modules. Mine are `infimech_bed_sensor.py` and `infimech_compat.py`.

## 4. Flash the STM32 (DFU, no opening the printer)

- Build settings: STM32F072, 8 MHz crystal, **no bootloader**, USB on PA11/PA12 (`scripts/stm32f072-mainboard.config`). Build on the PC with `scripts/fw_build.sh`, or take the ready-built v0.14.0 `.bin` from Releases.
- Entering the bootloader from the V853, as the vendor's `update_stm32.sh` does: GPIO228 = BOOT0 high, pulse GPIO142 = RESET low. Then flash:
  `dfu-util -d 0483:df11 -a 0 -s 0x08000000 -D klipper.bin`
- Read it back and compare: `-s 0x08000000:<size> -U readback.bin`. Set BOOT0 low and pulse RESET again.
- The USB name changes to `usb-Klipper_stm32f072xb_<chip id>-if00`. Put that in `[mcu] serial`.
- **Back to stock:** delete `/server/tmp/updatestm32`. At the next boot, Tina's `go.sh` reflashes the stock firmware. Keep that marker file in place otherwise.
- At power-on, start the Klipper that matches the firmware on the STM32 (I check the USB name in `kp.sh` / `local_mcu.sh`).

## 5. Debian 11 → 12

- Do it on the PC: copy the printer's Debian into a qemu armhf chroot, `apt full-upgrade` to bookworm, rebuild the Python environments, pack it, and copy it to `/server/deb12`.
- **Debian 12 won't start on the vendor kernel as-is.** On 4.9.191, syscalls 397 and 398 (statx and rseq on newer kernels) are vendor calls that return `EINVAL`, so glibc 2.36 fails. A seccomp wrapper doesn't help (no seccomp in this kernel).
- Fix: rebuild glibc 2.36 with three edits (`scripts/glibc_tx_edit.py`) and pin it in apt.
- Switch by renaming: `/server/tmp` → `/server/tmp_deb11`, `/server/deb12` → `/server/tmp`, then power-cycle. **Rollback** = rename back.

## 6. Moonraker v0.11 and updates from Fluidd

- No systemd in the chroot. Run each service in a small restart loop started from `/run.sh`.
- Set `[machine] provider: supervisord_cli` and add a `supervisorctl` stand-in (`scripts/supervisorctl`), so Fluidd's restart buttons and the update manager work.
- The update manager needs each repo on a branch with a tracking remote. Move `/home/gem/.git` (the vendor's leftover KIAUH repo) out of the way: it breaks the Fluidd entry.
- Keep add-on modules outside the Klipper repo and symlink them in. Klipper will still log its version as `-dirty`, which is cosmetic.

## 7. Screen

HelixScreen (`helixscreen-pi32`, fbdev) works at 480x272. Tina's boot animation (`/etc/init.d/show_start.sh`) keeps drawing on `/dev/fb0` until the stock screen stops it. When the stock screen isn't started, kill it yourself, or HelixScreen flickers.

`scripts/boot/helix_run.sh` starts HelixScreen in place of the stock screen and keeps it running. If HelixScreen fails 3 times in 5 minutes, it brings the stock screen back.

**Updating HelixScreen from Fluidd** (tested from v1.0.11 to v1.1.0). The chroot has no systemd, so the launcher does what HelixScreen's installer normally sets up:
- `[update_manager helixscreen]` (`type: web`, in `config/infimech_moonraker.conf`).
- Your HelixScreen files live in `printer_data/config/helixscreen/` and are linked into the install folder before every start. A Moonraker update deletes that folder, so this keeps them.
- After an update, the launcher restarts HelixScreen once the new release is fully unpacked.
- HelixScreen also relaunches itself on an update, outside the launcher. That copy holds its lock (`config/.helix-screen.lock`), so the launcher stops any copy it didn't start.
- v1.1.0 has no `helix-screen-fbdev`. One program, `helix-screen`, does fbdev, and the launcher picks whichever the release has.
- v1.1.0 may say this printer "looks like a Sovol SV06 ACE". It guesses that from Klipper's `smart_effector` module, which the TX uses for its piezo probe. Tap **Keep current**: the SV06 ACE profile adds settings meant for that printer, including a GPIO light pin.

## 8. After every Klipper update (the routine part)

Update Klipper in Fluidd, then:
```
# PC, Ubuntu (WSL)
bash fw_build.sh <VERSION>          # the Klipper version Fluidd shows, e.g. v0.14.0
```
```
rem PC, cmd, in the folder with the output
ssh root@<PRINTER_IP> "tar -xf - -C /server/tmp/home/gem/infimech/firmware" < fw-<VERSION>.tar
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/firmware/fw_update.sh --check"
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/firmware/fw_update.sh"
```
`fw_update.sh` does the following:
- refuses while printing;
- rebuilds the host MCU and checks the config offline;
- flashes the STM32, reads it back and compares;
- restarts Klipper and confirms both MCU versions.

If a flash fails, the STM32 stays in its bootloader (safe), and running the script again fixes it.

---

## Known quirks
- Debian 11 on this kernel: `ls -l` fails with "Invalid argument" (statx). Debian 12 with the rebuilt glibc doesn't have this problem.
- "MCU 'rpi' configured for 50Mhz but running at 49Mhz!" once, right after a firmware update. A Klipper restart cleared it.
- Debian's glibc security updates don't arrive while glibc is pinned. Each one needs a rebuild with the same edits.

## What's in this repository
- `REFERENCE.md`: hardware and system findings (GPIOs, I2C, bed sensor protocol, boot chain, pitfalls)
- `config/`: the full Klipper + Moonraker config, made generic (start with its `README.md`)
- `klippy_extras/`: `infimech_bed_sensor.py`, `infimech_compat.py`
- `firmware/`, `glibc/`: notes and checksums. **The binaries are under [Releases](https://github.com/yoyo8618/infimech-tx-v2-mainline/releases)**:
  - the STM32 firmware for Klipper v0.14.0
  - the rebuilt glibc packages for Debian 12
- `scripts/`:
  - `backup.bat`: step 1
  - `fw_build.sh`, `fw_update.sh`, `stm32f072-mainboard.config`: step 8
  - `glibc_tx_edit.py`, `pc_glibc.sh`: build the glibc yourself
  - `supervisorctl`: service control for Moonraker
  - `boot/`: `run.sh`, the restart loop, start scripts, the HelixScreen launcher (steps 4, 6, 7)
- `steps/`: **scripts for steps 3–7**, one per step, each with a `--check` mode and a way back. Start with [`steps/README.md`](steps/README.md). They're consolidated from the step-by-step packages that ran on my printer, and so far tested in simulation only. Testers wanted.

License: GPLv3 (see `LICENSE`). The STM32 firmware is built from unmodified Klipper. The glibc packages are LGPL: their source is Debian's, plus `scripts/glibc_tx_edit.py`.

## Feedback wanted (please open an Issue)
- Do you have a TX V2, or a Flying Bear S1 (reportedly the same hardware)? Which stock firmware version (stock screen firmware, and the `#OCTO-…` marker in the vendor config)?
- **Please run [`tools/tx_survey.sh`](tools/tx_survey.sh)** and attach its output to an Issue. It's read-only, takes about a minute, and masks IP and MAC addresses, the MCU chip ID and serial numbers. It shows whether your printer runs the same Tina, kernel and boot chain as the author's, which decides whether a prebuilt Debian 12 image and a one-step installer can work for everyone. Run it in cmd: `ssh root@<PRINTER_IP> "sh -s" < tx_survey.sh > tx_survey.txt 2>&1`
- Does your kernel also report `4.9.191`?
- Did a step script stop you, or do something you didn't expect? Please attach its `--check` output, or for step 3, `step3-config.diff`.
- Did you do only part of it (for example Klipper and HelixScreen, without Debian 12)? Did that work?
