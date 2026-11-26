# Infimech TX V2 - hardware and system reference

Findings from one stock TX V2 (Tina Linux, kernel 4.9.191, vendor config `#OCTO-v1.0.20-20250430`). Useful even without the full conversion.

### Platform details

- eMMC: p1 boot-resource, p2 env, p3 boot, p4 dtb, **p5 Tina root file system
  (4.5 GB, read-only)**, **p6 = `/server` (10 GB ext4, persists)**, plus
  boot0/boot1 hardware partitions. Tina `/tmp` is RAM.
- Tina: BusyBox 1.33.2, glibc 2.25, sshd, ntpd, crond, udhcpc, wpa_supplicant.
- Stock screen `/opt/FdmPrinter` (Qt 5.14.2, tslib); `/opt/profile.ini`
  holds its bed sensor sensitivities (Normal 1.5, Bedmesh 0.8).
- I2C bus 2: AHT21 (0x38), NS2009 (0x48), GT911 (0x5d), bed sensor (0x40).
  I2C bus 4: AXP2101 power management (0x34).
- Bed sensor protocol as the stock screen uses it:
  `i2ctransfer -y 2 w1@0x40 0x08 r8` = four 16-bit readings;
  `w1@0x40 0x00 r8` = read the four thresholds;
  `w9@0x40 0x00 <8 bytes>` = write them.
- GPIOs (sysfs numbers): 143 STM32 power enable, 256 USB host power,
  232 LCD backlight, 228 STM32 BOOT0, 142 STM32 reset.
- Fan outputs (vendor pinout PDF): part cooling PC9, hotend + board fan PC8,
  auxiliary 12038 fan PA8, optional chamber fan PA9, filter fan on the V853
  (`rpi:gpio225`), light strip `rpi:gpio141`.
- Vendor STM32 firmware is flashed by the vendor's `update_stm32_mainboard.sh`
  (`flash_usb.py -t stm32f072xb -d 0483:df11 -s 0x8000000`).
- The stock screen posts logs to a fixed vendor IP address
  (`<VENDOR_LOG_SERVER_IP>:8084/printer/log/upload`), which a DNS block
  cannot stop; `Network_select` pings a vendor host to choose eth0/wlan0.

### Boot chain

1. Tina `rcS` mounts `/server` (`MountServer`; **only if the mount fails** it
   formats p6 and wipes `/server`), powers the STM32 and USB host, then runs
   `nohup /server/tmp/go.sh`.
2. `go.sh` bind-mounts dev, sys, run, proc, dev/pts into `/server/tmp`,
   empties `/server/tmp/tmp`, and **flashes the stock STM32 firmware and
   reboots if `/server/tmp/updatestm32` is missing** (the marker must exist
   in every copy of the system). If `config/KAMP_Settings.cfg` is missing it
   runs `kamp_init.sh`. Then `chroot . ./init-service.sh` →
   `sudo -u gem -i /run.sh` → tmux panes: `kp.sh` (Klipper), `moon.sh`
   (Moonraker), `nginx`, `local_mcu.sh` (host MCU).
3. Tina also runs `Kilpper_check.sh` (vendor spelling): if the stock
   Klipper's `klippy/chelper/c_helper.so` is missing or empty it copies the
   vendor one back; if `printer.cfg` or `printer_config.cfg` in
   `printer_data/config` is empty or missing it copies the newest vendor
   backup over it. At shutdown `S100ki` runs `chroot /server/tmp /shutdown.sh`.

### Pitfalls

- Debian 11 `ls -l` / `ls -ld` fail with "Invalid argument" on this kernel
  (statx); scripts use globs, `readlink` or `find`.
- Soft `reboot` can leave the board black; use the power button.
- Module (`.py`) changes need a Klipper restart (a service restart, or a
  power cycle); `FIRMWARE_RESTART` does not reload Python code. Config
  changes need only `FIRMWARE_RESTART`.
- Windows: use cmd, not PowerShell, for `ssh ... < file` (PowerShell has no
  `<` and alters binary data through pipes); do not put `\$` in cmd one-liners.
- Moonraker answers "Server is busy" to a refresh until its own start-up
  check finishes.
- Moonraker needs repos on a branch with a tracking remote, refuses a web
  updater inside a git folder, and its Klipper "recover" installs Klipper's
  full package list (compilers).
- Background commands in a script fed through `ssh ... "sh -s" < script`
  need `< /dev/null`, or they read the rest of the script.
- Any extra `.py` file or symlink in `klippy/extras/` makes Klipper log its
  version with "-dirty", even if git ignores the file. This is by design and
  is cosmetic.
- HelixScreen v1.1.0 and later: one program, `bin/helix-screen`, for fbdev (`HELIX_DISPLAY_BACKEND=fbdev`); `helix-screen-fbdev` is gone. It holds `config/.helix-screen.lock`, and relaunches itself when Moonraker installs an update.
