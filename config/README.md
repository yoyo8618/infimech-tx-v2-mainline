# Klipper config for the Infimech TX V2 (mainline Klipper v0.14.0)

This is the config one TX V2 prints with every day, made generic. It goes in `/home/gem/printer_data/config_new/` (or your config folder).

**Before the first start**
1. `printer_config.cfg`, `[mcu] serial`: put in your board's name from `ls /dev/serial/by-id/`. You need the mainline STM32 firmware for this, because the stock firmware's name differs.
2. Copy `../klippy_extras/*.py` into `klipper/klippy/extras/`, or link them there. The config needs both.
3. `printer.cfg` includes `fluidd.cfg` and `timelapse.cfg`. Both already exist on a stock TX: they're links to `fluidd-config` and `moonraker-timelapse`.
4. Check it offline: `klippy.py printer.cfg -i /dev/null -o /dev/null -d <stm32.dict> -d rpi=<host klipper.dict> -l check.log`. Exit code 0 means OK.
5. Re-tune for your printer, as listed at the end of `printer.cfg`:
   - PID for the nozzle and bed;
   - input shaper (the printer has an ADXL345, see `[adxl345]`);
   - z_offset.

**Files**
- `printer.cfg`: includes, plus calibration values from one printer as a starting point
- `printer_config.cfg`: hardware: pins, motors, TMC2209, heaters, piezo probe, Z tilt, mesh, ADXL345, filament sensor
- `macros.cfg`:
  - homing (sensorless X/Y, Z with the bed probe)
  - nozzle wipe
  - `PRINT_START` / `PRINT_END` / `CANCEL_PRINT`
  - pause/resume
  - filament load/unload
- `fans_mainline.cfg`: the four fans as real Klipper fans. `M106 P1-P3` keep the stock meaning. `fans_stock.cfg` is the stock style.
- `screen.cfg`: macros and messages the **stock** touchscreen calls. You don't need it with HelixScreen.
- `infimech.cfg`: Klipper features plus the two add-on modules
- `init.cfg`: light on at start-up
- `moonraker.conf`, `infimech_moonraker.conf`: Moonraker v0.11 with the update manager. This needs the service setup from the guide (step 6).

**Changes from the stock config.** These are marked `changed:` in the files:
- `min_temp` set to 0, not -200, so a broken thermistor is caught.
- No `SAVE_CONFIG` after every mesh, which restarts mainline Klipper mid-print. The adaptive mesh is Klipper's own (`BED_MESH_CALIBRATE ADAPTIVE=1`).
- `debounce_delay: 10` on the filament sensor.
- Safer end, cancel and pause moves.
- Z1 driven the same way as Z.
- Bed `check_gain_time` set to 60.

**Slicer machine start G-code** (OrcaSlicer placeholders):
```
PRINT_START BED_TEMP=[bed_temperature_initial_layer_single] EXTRUDER_TEMP=[nozzle_temperature_initial_layer] PRINT_MIN={first_layer_print_min[0]},{first_layer_print_min[1]} BED_MAX={print_bed_max[0]}
M140 S[bed_temperature_initial_layer_single]
M104 S[nozzle_temperature_initial_layer]
```
Keep the whole `PRINT_START` on one line. Filter fan in the filament G-code: `M106 P3 S125` at the start, `M107 P3` at the end.

The add-on modules in `../klippy_extras` are GPLv3, like Klipper.
