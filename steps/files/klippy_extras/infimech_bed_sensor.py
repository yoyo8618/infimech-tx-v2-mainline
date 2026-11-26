# Infimech TX V2 piezo bed sensor (STM32G030 at I2C 0x40)
#
# Register map, confirmed on a stock TX V2 (values 16-bit, high byte first):
#   0x00-0x07  four trigger thresholds   (read/write)
#   0x08-0x0F  four live ADC readings    (read only, 12-bit)
# The sensor keeps thresholds in RAM only; they reset at power-on.
#
# Reference: github.com/Fantomiaso/Infimech-TX-v2-bed-sensor-driver (a
# Klipper driver for the same sensor on another board).
#
#   [infimech_bed_sensor]
#   i2c_mcu: rpi
#   i2c_bus: i2c.2
#   #i2c_address: 64
#   #thresholds: 250, 250, 250, 250
#   #   Written to the sensor when Klipper connects. Leave unset to keep
#   #   whatever the sensor (or the stock screen) already has.
#   #manage_thresholds: off
#   #   off:     Klipper leaves the thresholds alone (the stock screen sets
#   #            them while it is in use).
#   #   compare: Klipper works out the thresholds the same way but does not
#   #            write them; it reads what the stock screen wrote and prints
#   #            both ("Bed sensor check: ..."). For testing next to the
#   #            stock screen.
#   #   on:      Klipper sets the thresholds itself. Only without the stock
#   #            screen (two programs must not both write them).
#   #   auto:    "compare" while the stock screen (FdmPrinter) is running,
#   #            "on" when it is not (HelixScreen or no screen). Checked at
#   #            every bed shake and mode change.
#   #normal_sensitivity: 1.4
#   #mesh_sensitivity: 0.7
#   #   1.4 / 0.7 match the stock screen's thresholds as Klipper measures
#   #   them (the screen's own settings are 1.5 / 0.8, but it measures over
#   #   a slightly longer window).
#   #homing_threshold: 525
#   #top_fraction: 0.2
#   #min_margin: 20
#   #sample_interval: 0.02
#
# How the thresholds are chosen (measured from the stock screen): during
# the bed shake (Z_DOUDONG) each channel is sampled; with the median as
# the resting level and the noise as the average of the largest 20% of
# deviations from it,
#     threshold = resting level + (1 + sensitivity) * noise
# with sensitivity 1.4 normally and 0.7 for the bed mesh. Z homing uses a
# fixed 525.
#
# Commands:
#   BED_SENSOR_READ
#   BED_SENSOR_SET THRESHOLDS=a,b,c,d    or    BED_SENSOR_SET VALUE=n
#   BED_SENSOR_CALIBRATE ACTION=START|STOP  (called by Z_DOUDONG)
#   BED_SENSOR_MODE MODE=NORMAL|MESH|HOMING (called by the macros)
# CALIBRATE and MODE do nothing when manage_thresholds is off (or auto
# while the stock screen is running, apart from the comparison).
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging, os, struct
from . import bus

DEFAULT_ADDR = 0x40
REG_THRESHOLDS = 0x00
REG_ADC = 0x08
MAX_VALUE = 4095
MIN_SAMPLES = 50
STOCK_SCREEN = 'FdmPrinter'


def stock_screen_running(proc='/proc'):
    """True if the stock touchscreen program is running (the Debian chroot
    shares /proc with Tina, so its processes are visible here)."""
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        return True     # cannot tell: behave as if it were (write nothing)
    for pid in pids:
        try:
            with open(os.path.join(proc, pid, 'comm')) as f:
                if f.read().strip() == STOCK_SCREEN:
                    return True
        except (IOError, OSError):
            pass
    return False


def parse_thresholds(text, error):
    try:
        vals = [int(v.strip()) for v in text.split(',')]
    except ValueError:
        raise error("thresholds must be 4 comma separated integers")
    if len(vals) == 1:
        vals = vals * 4
    if len(vals) != 4 or not all(1 <= v <= MAX_VALUE for v in vals):
        raise error("thresholds must be 1 or 4 integers between 1 and %d"
                    % (MAX_VALUE,))
    return vals


def median(vals):
    s = sorted(vals)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.


def channel_noise(samples, top_fraction):
    """Resting level (median) and noise (mean of the largest deviations)."""
    base = median(samples)
    devs = sorted((abs(v - base) for v in samples), reverse=True)
    count = max(1, int(len(devs) * top_fraction))
    return base, sum(devs[:count]) / float(count)


def thresholds_from(levels, sensitivity, min_margin):
    out = []
    for base, noise in levels:
        margin = max(min_margin, (1. + sensitivity) * noise)
        out.append(int(min(MAX_VALUE, round(base + margin))))
    return out


class InfimechBedSensor:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.i2c = bus.MCU_I2C_from_config(config, default_addr=DEFAULT_ADDR)
        # Klipper allows one outstanding query per (response, oid): two
        # overlapping reads (the sampler and a command) make the replies go
        # to the wrong waiter and end in a KeyError. Every access to the
        # sensor goes through this lock.
        self.i2c_mutex = self.reactor.mutex()
        self.thresholds = None
        self.adc = None
        self.startup_thresholds = None
        text = config.get('thresholds', None)
        if text is not None:
            self.startup_thresholds = parse_thresholds(text, config.error)
            # Queued by the bus code and sent once the MCU is configured
            self._write(self.startup_thresholds)
        self.manage = config.getchoice('manage_thresholds',
                                       ['off', 'compare', 'on', 'auto'],
                                       'off')
        self.normal_sens = config.getfloat('normal_sensitivity', 1.4, minval=0.)
        self.mesh_sens = config.getfloat('mesh_sensitivity', 0.7, minval=0.)
        self.homing_thr = config.getint('homing_threshold', 525,
                                        minval=1, maxval=MAX_VALUE)
        self.top_fraction = config.getfloat('top_fraction', 0.2,
                                            above=0., maxval=1.)
        self.min_margin = config.getint('min_margin', 20, minval=0)
        self.interval = config.getfloat('sample_interval', 0.02, above=0.)
        self.levels = None          # [(resting level, noise)] x 4
        self.active = 'off' if self.manage == 'off' else None
        self.fallback = None        # thresholds found before any shake
        self.mode = None
        self.samples = None
        self.sample_errors = 0
        self.sample_timer = None
        # compare mode: thresholds the stock screen wrote
        self.start_thr = None
        self.screen_thr = None
        self.last_check = None
        self.pending_check = None
        self.check_timer = self.reactor.register_timer(self._check_event,
                                                       self.reactor.NEVER)
        self.gcode = gcode = self.printer.lookup_object('gcode')
        gcode.register_command('BED_SENSOR_READ', self.cmd_READ,
                               desc="Read piezo bed sensor thresholds and"
                               " live values")
        gcode.register_command('BED_SENSOR_SET', self.cmd_SET,
                               desc="Set piezo bed sensor thresholds")
        gcode.register_command('BED_SENSOR_CALIBRATE', self.cmd_CALIBRATE,
                               desc="Measure bed sensor noise (bed shake)")
        gcode.register_command('BED_SENSOR_MODE', self.cmd_MODE,
                               desc="Select bed sensor thresholds")

    def _write(self, vals):
        data = [REG_THRESHOLDS] + list(struct.pack('>4H', *vals))
        with self.i2c_mutex:
            self.i2c.i2c_write(data)
        self.thresholds = list(vals)

    def _read(self):
        with self.i2c_mutex:
            params = self.i2c.i2c_read([REG_THRESHOLDS], 16)
        if not params or not params.get('response'):
            raise self.printer.command_error("bed sensor: no response")
        data = bytes(bytearray(params['response']))
        if len(data) != 16:
            raise self.printer.command_error(
                "bed sensor: short read (%d bytes)" % (len(data),))
        vals = struct.unpack('>8H', data)
        self.thresholds = list(vals[0:4])
        self.adc = list(vals[4:8])
        return self.thresholds, self.adc

    def _set_checked(self, vals):
        self._write(vals)
        thr, adc = self._read()
        if thr != list(vals):
            msg = "bed sensor: wrote %s but read back %s" % (list(vals), thr)
            raise self.printer.command_error(msg)
        return thr, adc

    # --- noise measurement during the bed shake
    def _note_screen(self, thr):
        # compare mode: the first new (non-homing) values seen are the
        # ones the stock screen worked out from this shake
        if self.start_thr is None:
            self.start_thr = thr
        elif (self.screen_thr is None and thr != self.start_thr
              and thr != [self.homing_thr] * 4):
            self.screen_thr = thr

    def _sample_event(self, eventtime):
        samples = self.samples   # the read below may outlast a STOP
        if samples is None:
            return self.reactor.NEVER
        try:
            thr, adc = self._read()
            for ch in range(4):
                samples[ch].append(adc[ch])
            if samples is self.samples:
                self._note_screen(list(thr))
        except self.printer.command_error:
            self.sample_errors += 1
        return self.reactor.monotonic() + self.interval

    def _stop_sampling(self):
        samples = self.samples
        self.samples = None
        if self.sample_timer is not None:
            self.reactor.unregister_timer(self.sample_timer)
            self.sample_timer = None
        return samples

    def _active(self):
        if self.manage == 'auto':
            act = 'compare' if stock_screen_running() else 'on'
            if act != self.active:
                logging.info("Bed sensor: manage_thresholds auto -> %s", act)
        else:
            act = self.manage
        self.active = act
        return act

    def cmd_CALIBRATE(self, gcmd):
        act = self._active()
        if act == 'off':
            return
        action = gcmd.get('ACTION').upper()
        toolhead = self.printer.lookup_object('toolhead')
        if action == 'START':
            toolhead.wait_moves()
            self._stop_sampling()
            self.samples = [[], [], [], []]
            self.sample_errors = 0
            self.start_thr = self.screen_thr = None
            self.sample_timer = self.reactor.register_timer(
                self._sample_event, self.reactor.NOW)
        elif action == 'STOP':
            toolhead.wait_moves()
            samples = self._stop_sampling()
            if samples is None:
                raise gcmd.error("BED_SENSOR_CALIBRATE: STOP without START")
            count = len(samples[0])
            if count < MIN_SAMPLES:
                msg = ("bed sensor: only %d samples (%d read errors) during"
                       " the bed shake; thresholds unchanged"
                       % (count, self.sample_errors))
                logging.warning(msg)
                gcmd.respond_info(msg)
                return
            self.levels = [channel_noise(s, self.top_fraction)
                           for s in samples]
            logging.info("Bed sensor calibration: %d samples, %d errors,"
                         " levels %s", count, self.sample_errors,
                         ["%.1f/%.1f" % l for l in self.levels])
            if act == 'compare':
                if self.screen_thr is None:
                    try:
                        self._note_screen(list(self._read()[0]))
                    except self.printer.command_error:
                        pass
                self._report('shake, %d samples' % (count,),
                             self._values('NORMAL'), self.screen_thr)
                return
            self._apply('NORMAL')
        else:
            raise gcmd.error("BED_SENSOR_CALIBRATE: ACTION must be START"
                             " or STOP")

    def _values(self, mode):
        if mode == 'HOMING':
            return [self.homing_thr] * 4
        if self.levels is None:
            return None
        sens = self.mesh_sens if mode == 'MESH' else self.normal_sens
        return thresholds_from(self.levels, sens, self.min_margin)

    def _apply(self, mode):
        if self.levels is None and self.fallback is None and mode != 'NORMAL':
            # No bed shake measured yet: remember what the sensor has now,
            # so NORMAL can go back to it instead of staying at 525.
            self.fallback = self._read()[0]
        vals = self._values(mode)
        if vals is None:
            vals = self.fallback
        if vals is None:
            return
        self._set_checked(vals)
        self.mode = mode
        logging.info("Bed sensor thresholds (%s): %s", mode, vals)

    # --- compare mode
    def _report(self, what, ours, screen):
        if ours is None:
            msg = "Bed sensor check (%s): no bed shake measured yet" % (what,)
        elif screen is None:
            msg = ("Bed sensor check (%s): Klipper %s, screen value not seen"
                   % (what, ours))
        else:
            diff = [a - b for a, b in zip(ours, screen)]
            msg = ("Bed sensor check (%s): Klipper %s screen %s diff %s"
                   % (what, ours, screen, diff))
        self.last_check = msg
        self.gcode.respond_info(msg)    # also goes to klippy.log

    def _check_event(self, eventtime):
        mode, ours = self.pending_check
        self.pending_check = None
        try:
            screen = list(self._read()[0])
        except self.printer.command_error:
            screen = None
        self._report(mode.lower(), ours, screen)
        return self.reactor.NEVER

    def cmd_MODE(self, gcmd):
        act = self._active()
        if act == 'off':
            return
        mode = gcmd.get('MODE').upper()
        if mode not in ('NORMAL', 'MESH', 'HOMING'):
            raise gcmd.error("BED_SENSOR_MODE: MODE must be NORMAL, MESH"
                             " or HOMING")
        if act == 'compare':
            # The screen writes HOMING / MESH values when it sees the
            # message just before this command; read them a little later.
            # (NORMAL is only a return to the values already checked.)
            self.mode = mode
            if mode != 'NORMAL':
                self.pending_check = (mode, self._values(mode))
                self.reactor.update_timer(self.check_timer,
                                          self.reactor.monotonic() + 1.5)
            return
        # No wait for queued moves: the sensor only matters while probing.
        # The write goes out at once and is read back before this command
        # returns, so a PROBE after it always uses the new values.
        self._apply(mode)

    # --- manual commands
    def cmd_READ(self, gcmd):
        thr, adc = self._read()
        lines = ["Bed sensor  ch: live / threshold (margin)"]
        for i in range(4):
            lines.append("  %d: %4d / %4d (%+d)"
                         % (i, adc[i], thr[i], thr[i] - adc[i]))
        if self.manage != 'off':
            act = self._active()
            lines.append("manage_thresholds: %s%s, mode: %s"
                         % (self.manage,
                            " (now %s)" % act if self.manage == 'auto' else "",
                            self.mode))
            for mode in ('NORMAL', 'MESH'):
                lines.append("  %s from last shake: %s"
                             % (mode.lower(), self._values(mode)))
        gcmd.respond_info("\n".join(lines))

    def cmd_SET(self, gcmd):
        text = gcmd.get('THRESHOLDS', None)
        if text is None:
            text = str(gcmd.get_int('VALUE', minval=1, maxval=MAX_VALUE))
        vals = parse_thresholds(text, gcmd.error)
        toolhead = self.printer.lookup_object('toolhead')
        toolhead.wait_moves()
        thr, adc = self._set_checked(vals)
        logging.info("Bed sensor thresholds set to %s", vals)
        gcmd.respond_info("Bed sensor thresholds: %s (live %s)" % (thr, adc))

    def get_status(self, eventtime):
        return {'thresholds': self.thresholds, 'adc': self.adc,
                'startup_thresholds': self.startup_thresholds,
                'manage_thresholds': self.manage, 'active': self.active,
                'mode': self.mode,
                'levels': self.levels, 'last_check': self.last_check}


def load_config(config):
    return InfimechBedSensor(config)
