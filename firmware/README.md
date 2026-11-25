# STM32 firmware: Klipper v0.14.0 for the Infimech TX V2 mainboard

Only for a printer running **Klipper v0.14.0** (commit `c9559fa04ec6b11fb1a9a1610903546319fcf310`). For any other version, build your own with `../scripts/fw_build.sh`.

**Download** the `.bin`, `.dict` and `.bin.md5` from this repository's **Releases**. This folder holds the notes and the build settings.

- `klipper-v0.14.0-stm32f072-mainboard.bin`: the firmware, 46548 bytes
  - md5 `0682e3ea97134c1e77d558d8ae06b95e`
  - sha256 `3ddbb07fb905f448db9128a188f6315036c18a44ef574f702cc66447893793e4`
- `.dict`: its command dictionary, for offline config checks (`klippy.py ... -d <file>`)
  - sha256 `232caadbb1ca75ea5bb60899e8bb09f175caa41235576e2780e4d539852bed31`
- `.config`: the exact build settings
  - STM32F072
  - 8 MHz crystal
  - no bootloader (flash starts at 0x08000000)
  - USB on PA11/PA12
  - USB serial = chip ID
- `build-v0.14.0.txt`: compiler and commit

After flashing, the board shows up as `/dev/serial/by-id/usb-Klipper_stm32f072xb_<chip id>-if00`. Put that in `[mcu] serial`.

Flash it with `../scripts/fw_update.sh`:
- put these files in `/home/gem/infimech/firmware/` inside the chroot;
- run `--check` first.

**Source (GPLv3):** Klipper, https://github.com/Klipper3d/klipper, tag `v0.14.0`. Built unmodified with the `.config` above. Rebuilding gives the same program. The md5 can differ, because Python's zlib compresses the embedded command dictionary differently from system to system.
