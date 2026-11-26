# Infimech TX V2 → mainline Klipper, Debian 12, updates from Fluidd

**Status:** working on one printer (mine) since Nov 2026, with prints running normally. This is a description of what was done, not a one-click installer yet. **Feedback wanted**: open an Issue.

> **How this was made:** the scripts, add-on modules and config changes were written with an AI assistant (Claude). I ran and checked every step on my own TX V2. Read the scripts before you run them, run the `--check` modes first, and **make the backup in step 1**.

**What you end up with**
- Mainline Klipper v0.14.0: host, STM32 mainboard firmware and the host MCU (`rpi`)
- Moonraker v0.11, Fluidd v1.38, HelixScreen on the touchscreen
- Debian 12 with security updates, and Klipper/Moonraker/Fluidd updates, all from Fluidd's update manager
- A tested way to rebuild and flash the firmware after each Klipper update
- The stock screen stays as an automatic fallback, and every step can be undone

**What stays vendor:** Tina Linux and its 4.9 kernel. No mainline kernel supports the V853's display and Wi-Fi yet. Debian runs in Tina's chroot at `/server/tmp`, as on stock.

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

**A vendor (Infimech/OctopusWorks) firmware update can undo all of this.** It's built for the stock layout. It's likely to replace Klipper and its config in `/server/tmp`, reflash the stock STM32 firmware and reset the start scripts. Your backup from step 1 would get you back, but it's easier not to let one in.

What's known about the stock software:
- The update client is in the stock touchscreen app (`/opt/FdmPrinter`), which talks to `slice-update.octopusworks.com`. Whether it ever installs without asking is unknown, so treat it as if it could.
- Tina's `Network_select` pings `update.octopusworks.com` in a loop to choose between Ethernet and Wi-Fi.
- The stock screen also has a raw address for uploading logs: `120.77.245.96:8084/printer/log/upload`. A DNS rule can't block a raw address.

What to do:
1. In your DNS (AdGuard Home, Pi-hole, router), add a rewrite for `*.octopusworks.com` pointing to **any local IP that answers ping** (another device on your network). Don't block the name outright: if the ping fails, Tina thinks the network is down and keeps switching between Ethernet and Wi-Fi.
2. Optionally, block outgoing traffic to `120.77.245.96` in your router's firewall.
3. Never accept an update offered on the stock screen. With HelixScreen installed, the stock screen only comes back as a fallback.

After the conversion, mainline updates come only from Fluidd (Settings → Software Updates). Nothing updates by itself: Moonraker's automatic refresh is off, and HelixScreen's own updater is disabled.

## 3. Mainline Klipper next to stock

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

The scripts that did steps 3–7 on my printer (installing, config changes, building the Debian 12 system) were written step by step for that one printer, so they aren't here yet. I'm turning them into an installer.

License: GPLv3 (see `LICENSE`). The STM32 firmware is built from unmodified Klipper. The glibc packages are LGPL: their source is Debian's, plus `scripts/glibc_tx_edit.py`.

## Feedback wanted (please open an Issue)
- Do you have a TX V2, or a Flying Bear S1 (reportedly the same hardware)? Which stock firmware version (stock screen firmware, and the `#OCTO-…` marker in the vendor config)?
- Does your kernel also report `4.9.191`?
- Would you try an installer, and with which parts: Klipper only, or the full Debian 12 setup?
