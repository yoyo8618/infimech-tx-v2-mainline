# Step scripts (steps 3–7 of the guide)

These scripts do steps 3–7 of the main [README](../README.md) on a stock Infimech TX V2. Each one has a `--check` mode that changes nothing, and each change has a way back.

> **Status: testers wanted.** Every part ran on one TX V2, one step at a time. The scripts here are consolidated final versions of those step packages. They were tested in simulation: a stock config folder rebuilt from that printer, fake GPIO, `dfu-util` and USB. They have **not** run on a second printer yet. Run the `--check` mode first and keep its output. If something stops you, open an Issue with that output.

**Before you start**
1. Do steps 1 (backup) and 2 (block vendor updates) of the guide.
2. Step 3 builds the new config from **your** stock config, and keeps your calibration: the `SAVE_CONFIG` block, `z_offset`, bed PID, extruder PID, X/Y `rotation_distance` and the nozzle wipe depths. It works with these vendor versions of `printer_config.cfg` (its first line): `#OCTO-v1.0.20-20250430`, `#OCTO-v1.0.18-20241213`, `#OCTO-v1.0.17-20240925`, `#OCTO-v1.0.15-20240904`. Your own macros don't matter (they are replaced); only the hardware sections are compared. In `printer.cfg` only the stock sections may be there (`TEST_SPEED.cfg` and `[skew_correction]` are optional). With any other difference it stops, changes nothing, and writes a diff. Please send that diff in an Issue.
   - The new config is made from v1.0.20. With an older version, step 3 lists the values that change to the v1.0.20 ones (v1.0.17 and v1.0.18: none; v1.0.15: probe and Z-tilt tolerances, filament runout pause delay, hotend fan temperature, resonance test range). Your X/Y `rotation_distance` stays as it is.
   - No vendor config has a chamber temperature sensor. If you added one yourself as `[temperature_sensor CHAMBER]` in `printer_config.cfg`, step 3 copies that section as it is. If you didn't, the new config has none.
3. Run every step with the printer idle.
4. Power-cycle with the button. Never use `reboot`.
5. In Windows, use **cmd** (not PowerShell) for commands with `<` or `>`.

**Copy the scripts to the printer** (from the folder that contains `steps`, in cmd or the Ubuntu/WSL window):
```
tar -cf - steps | ssh root@<PRINTER_IP> "mkdir -p /server/tmp/home/gem/infimech && tar -xf - -C /server/tmp/home/gem/infimech"
```

## Step 3 – mainline Klipper next to stock (in the chroot, ~10 min)
```
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/3_klipper.sh --check" > step3_check.txt 2>&1
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/3_klipper.sh" > step3.txt 2>&1
```
It installs these, and runs a batch-mode test print at the end. Nothing running changes.
- Klipper v0.14.0 in `/home/gem/klipper-new`, a git clone on branch `master`. The printer needs internet for this.
- The host MCU program in `/home/gem/klipper-host`.
- The two add-on modules in `infimech/klippy_extras`, linked into Klipper.
- `printer_data/config_new`, built from your stock config.

Undo: `3_undo.sh` (moves everything into `infimech/backup/`).

## Step 4 – flash the STM32 and switch at power-on
First put the firmware on the printer. From the GitHub release, or built with `scripts/fw_build.sh`:
```
ssh root@<PRINTER_IP> "mkdir -p /server/tmp/home/gem/infimech/firmware"
ssh root@<PRINTER_IP> "cat > /server/tmp/home/gem/infimech/firmware/klipper-v0.14.0-stm32f072-mainboard.bin" < klipper-v0.14.0-stm32f072-mainboard.bin
ssh root@<PRINTER_IP> "cat > /server/tmp/home/gem/infimech/firmware/klipper-v0.14.0-stm32f072-mainboard.bin.md5" < klipper-v0.14.0-stm32f072-mainboard.bin.md5
```
Then:
```
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/4_boot.sh --check"
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/4_boot.sh" > step4_boot.txt 2>&1
ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_flash.sh --check"
ssh root@<PRINTER_IP> "sh /server/tmp/home/gem/infimech/steps/4_flash.sh" > step4_flash.txt 2>&1
```
Then power-cycle.
- `4_boot.sh` (in the chroot) installs start scripts that choose by the STM32's USB name: mainline firmware starts the new Klipper, stock firmware starts the stock one. It also makes `printer_data/config` a link to `config_new`, so Fluidd edits the config Klipper really uses. The stock Klipper keeps using `config_stock`.
- `4_flash.sh` (on Tina, not in the chroot) stops the stock Klipper and flashes the STM32 through its ROM bootloader (DFU). It reads the flash back and compares, then writes the board's new USB name into the config. If a flash fails, the STM32 stays in its bootloader (safe); run it again.

Way back: `sh /server/tmp/home/gem/infimech/steps/4_back_to_stock.sh` (add `--full` to also restore the stock start scripts and config folder), then power-cycle. Tina's own `go.sh` reflashes the stock firmware.

## Steps 5 and 6 – Debian 12 with Moonraker v0.11 (built on a Windows PC, ~1–2 h)
Folder `5_debian12/`. The Debian 12 system is built on the PC from a copy of **your** printer's Debian, in an ARM emulator. Moonraker v0.11, the update manager and the service control (step 6 of the guide) are part of this build.

1. **PC set-up, once** (PowerShell as admin: `wsl --install -d Ubuntu-24.04`; then in the Ubuntu window):
   ```
   sudo apt update && sudo apt install -y qemu-user-static binfmt-support
   ln -s "/mnt/c/<folder that contains steps>" ~/fw
   sudo mkdir -p /srv/tx && sudo chown $USER /srv/tx
   ```
2. **Snapshot of the printer's Debian** (Ubuntu window; leaves out G-code files):
   ```
   ssh root@<PRINTER_IP> "chroot /server/tmp sh -c 'cd / && tar --one-file-system --numeric-owner -cf - --exclude=./home/gem/printer_data/gcodes --exclude=./home/gem/.cache --exclude=./tmp . | gzip -1'" > /srv/tx/deb11-snapshot.tar.gz
   sudo mkdir /srv/tx/deb11 && sudo tar --numeric-owner -xpzf /srv/tx/deb11-snapshot.tar.gz -C /srv/tx/deb11 && sudo mkdir -m 1777 /srv/tx/deb11/tmp
   ```
3. **Build** (Ubuntu window, one after the other; each writes a log):
   ```
   sudo bash ~/fw/steps/5_debian12/pc_build_a.sh 2>&1 | tee pc_build_a.log   # 11 -> 12 upgrade, 30-90 min
   sudo bash ~/fw/steps/5_debian12/pc_build_b.sh 2>&1 | tee pc_build_b.log   # Python 3.11 envs, Moonraker v0.11
   sudo bash ~/fw/steps/5_debian12/pc_build_c.sh 2>&1 | tee pc_build_c.log   # services, update manager, tests
   sudo bash ~/fw/steps/5_debian12/pc_glibc_release.sh <folder with the release .debs + SHA256SUMS> 2>&1 | tee pc_glibc.log
   #   or build glibc yourself (~20+ min): sudo bash ~/fw/steps/5_debian12/pc_glibc.sh 2>&1 | tee pc_glibc.log
   sudo bash ~/fw/steps/5_debian12/pc_test.sh 2>&1 | tee pc_test.log
   sudo bash ~/fw/steps/5_debian12/pc_pack.sh 2>&1 | tee pc_pack.log
   ```
   The glibc must be the rebuilt one (see the main README, step 5): stock Debian 12 can't start on the vendor kernel.
4. **Send it to the printer and test it there.** The running system is not changed:
   ```
   ssh root@<PRINTER_IP> "cat > /server/deb12_receive.sh" < ~/fw/steps/5_debian12/deb12_receive.sh
   ssh root@<PRINTER_IP> "sh /server/deb12_receive.sh $(cat /srv/tx/deb12.count)" < /srv/tx/deb12.tar.gz
   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_test.sh > deb12_test.txt 2>&1
   ```
5. **Switch** (copies your configs, Moonraker database and settings across, then renames `/server/tmp` → `/server/tmp_deb11` and `/server/deb12` → `/server/tmp`), then power-cycle:
   ```
   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_switch.sh > deb12_switch.txt 2>&1
   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb12_after.sh > deb12_after.txt 2>&1   # after the power cycle
   ```
   Way back: `deb12_rollback.sh` (renames back), then power-cycle. Keep `/server/tmp_deb11` until you're sure.
6. **Later, when you're sure:** snapshot both systems to the PC, then remove the old Debian 11 to free its space. In the Ubuntu window, with the printer idle (Moonraker is stopped for a few minutes during the Debian 12 copy; G-code files, timelapse files and caches are left out of it):
   ```
   bash ~/fw/steps/5_debian12/pc_snapshot.sh <PRINTER_IP>      # -> ~/fw/snapshots/deb11-<date>.tar.gz, deb12-<date>.tar.gz
   ssh root@<PRINTER_IP> "sh -s" < ~/fw/steps/5_debian12/deb11_remove.sh
   ```
   `deb11_remove.sh` only runs after a checked Debian 11 snapshot (the marker `/server/tmp_deb11/.snapshot_ok`). After it, `deb12_rollback.sh` needs the old system back first:
   ```
   ssh root@<PRINTER_IP> "[ ! -e /server/tmp_deb11 ] && mkdir /server/tmp/root/deb11_restore && chroot /server/tmp tar --numeric-owner -xpzf - -C /root/deb11_restore && mv /server/tmp/root/deb11_restore /server/tmp_deb11" < ~/fw/snapshots/deb11-<date>.tar.gz
   ```

After step 5, run `scripts/fw_update.sh` once. It rebuilds the host MCU program with Debian 12's compiler.

## Step 7 – HelixScreen (in the chroot)
```
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/7_screen.sh --check"
ssh root@<PRINTER_IP> "chroot /server/tmp bash /home/gem/infimech/steps/7_screen.sh" > step7.txt 2>&1
```
This needs step 4.
- It downloads HelixScreen v1.1.0 (`helixscreen-pi32.zip`). You can also put the zip in `/home/gem/infimech/` yourself.
- It installs the launcher and the backlight helper, and switches the touchscreen to HelixScreen.
- After step 5 it also adds HelixScreen to Fluidd's updates. Run it again after step 5 if you did step 7 first.
- On the first start, HelixScreen runs its setup wizard. If it says the printer "looks like a Sovol SV06 ACE", tap **Keep current**.

Back to the stock screen: `chroot /server/tmp bash /home/gem/infimech/screen.sh stock`.

## Step 8 – after every Klipper update
`scripts/fw_build.sh` on the PC, then `scripts/fw_update.sh` on the printer. See the main README.

## What's in `files/`
- `config/`: the mainline config templates.
- `vendor_expected/`: the stock `printer_config.cfg` of each known vendor version (v1.0.20 from the author's printer; v1.0.15, v1.0.17 and v1.0.18 from the public backup [Loaf-God7/TXv2-Backup](https://github.com/Loaf-God7/TXv2-Backup)), with placeholders for the lines that differ per printer.
- `make_config.py`: builds `config_new` from the templates and your stock config.
- The add-on modules, the start scripts (`kp.sh`, `local_mcu.sh`, `which_klipper.sh`, `klipper_links.sh`), the service loop and `supervisorctl` stand-in, and the screen files.
- The v0.14.0 STM32 command dictionary, used for offline checks.
