# Infimech TX compatibility helpers for mainline Klipper
#
# Re-implements the small set of vendor ("OCTO") Klipper changes that the
# stock touchscreen and macros rely on, as a stand-alone module instead of
# edits to Klipper's core files.
#
#   [infimech_compat]
#   #probe_premature_retries: 3
#   #   How many times to retry a probe move that reports
#   #   "Probe triggered prior to movement" before giving up.
#   #   0 disables the retry (stock upstream behaviour).
#   #probe_retry_dwell: 0.5
#   #   Seconds to wait before each retry.
#   #save_config_restart_while_printing: False
#   #   Stock Infimech Klipper never restarts on SAVE_CONFIG, and the stock
#   #   screen / macros save the bed mesh in the middle of a print. With the
#   #   default (False) a SAVE_CONFIG (or SAVE_CONFIG_BASE) issued while a
#   #   print is running or paused still saves, but does NOT restart Klipper,
#   #   so the print continues. Outside a print SAVE_CONFIG behaves normally.
#
# Provides:
#   STEPPER_BUZZ_TEST_1 STEPPER=<name>   buzz a stepper once
#   STEPPER_BUZZ_TEST_2 STEPPER=<name>   buzz a stepper twice
#
# The vendor 10 s filament-runout debounce needs no code on mainline:
# add "debounce_delay: 10" to [filament_switch_sensor fila_sensor].
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
from . import force_move

PREMATURE_MSG = "Probe triggered prior to movement"


class InfimechCompat:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.retries = config.getint('probe_premature_retries', 3, minval=0)
        self.retry_dwell = config.getfloat('probe_retry_dwell', 0.5, minval=0.)
        self.force_move = self.printer.load_object(config, 'force_move')
        gcode = self.printer.lookup_object('gcode')
        for count in (1, 2):
            gcode.register_command(
                'STEPPER_BUZZ_TEST_%d' % (count,),
                (lambda gcmd, c=count: self._buzz(gcmd, c)),
                desc="Oscillate a stepper %d time(s) (Infimech self-test)"
                % (count,))
        if self.retries:
            self.printer.register_event_handler("klippy:connect",
                                                self._wrap_probing_move)
        # SAVE_CONFIG must not restart Klipper in the middle of a print.
        # Replace the built-in handler now, before [gcode_macro SAVE_CONFIG]
        # renames it to SAVE_CONFIG_BASE at connect time.
        self.restart_while_printing = config.getboolean(
            'save_config_restart_while_printing', False)
        if not self.restart_while_printing:
            desc = gcode.gcode_help.get('SAVE_CONFIG')
            # Keep Klipper's own handler (whatever object it lives on)
            self.orig_save_config = gcode.register_command('SAVE_CONFIG', None)
            if self.orig_save_config is None:
                raise config.error("infimech_compat: SAVE_CONFIG not found")
            gcode.register_command('SAVE_CONFIG', self.cmd_SAVE_CONFIG,
                                   desc=desc)
            logging.info("infimech_compat: SAVE_CONFIG restart protection"
                         " active")

    def _is_printing(self):
        eventtime = self.printer.get_reactor().monotonic()
        pstats = self.printer.lookup_object('print_stats', None)
        if pstats is not None and pstats.get_status(eventtime).get(
                'state') in ('printing', 'paused'):
            return True
        vsd = self.printer.lookup_object('virtual_sdcard', None)
        return vsd is not None and vsd.is_active()

    def cmd_SAVE_CONFIG(self, gcmd):
        if not self._is_printing():
            self.orig_save_config(gcmd)
            return
        gcode = self.printer.lookup_object('gcode')
        skipped = []
        gcode.request_restart = lambda result: skipped.append(result)
        try:
            self.orig_save_config(gcmd)
        finally:
            del gcode.request_restart
        logging.info("SAVE_CONFIG during a print: saved, restart skipped")
        gcmd.respond_info("SAVE_CONFIG saved during a print; Klipper was not"
                          " restarted (the print continues)")

    # STEPPER_BUZZ_TEST_1 / _2 (used by the stock touchscreen self-test)
    def _buzz(self, gcmd, count):
        fm = self.force_move
        name = gcmd.get('STEPPER')
        try:
            stepper = fm.lookup_stepper(name)
        except self.printer.config_error as e:
            raise gcmd.error(str(e))
        logging.info("Stepper buzz test x%d %s", count, stepper.get_name())
        did_enable = fm._force_enable(stepper)
        toolhead = self.printer.lookup_object('toolhead')
        dist, speed = force_move.BUZZ_DISTANCE, force_move.BUZZ_VELOCITY
        if stepper.units_in_radians():
            dist = force_move.BUZZ_RADIANS_DISTANCE
            speed = force_move.BUZZ_RADIANS_VELOCITY
        for i in range(count):
            fm.manual_move(stepper, dist, speed)
            toolhead.dwell(.050)
            fm.manual_move(stepper, -dist, speed)
            toolhead.dwell(.450)
        fm._restore_enable(stepper, did_enable)

    # Retry probe moves that trigger before moving (noisy strain-gauge probe)
    def _wrap_probing_move(self):
        phoming = self.printer.lookup_object('homing')
        orig = phoming.probing_move
        gcode = self.printer.lookup_object('gcode')
        toolhead = self.printer.lookup_object('toolhead')
        retries, dwell = self.retries, self.retry_dwell
        command_error = self.printer.command_error
        def probing_move(*args, **kwargs):
            attempt = 0
            while True:
                try:
                    return orig(*args, **kwargs)
                except command_error as e:
                    if (not str(e).startswith(PREMATURE_MSG)
                            or attempt >= retries
                            or self.printer.is_shutdown()):
                        raise
                gcode.respond_info(
                    "%s.Attempted again for the %d time"
                    % (PREMATURE_MSG, attempt))
                attempt += 1
                toolhead.dwell(dwell)
        phoming.probing_move = probing_move


def load_config(config):
    return InfimechCompat(config)
