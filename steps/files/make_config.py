#!/usr/bin/env python3
# Build the mainline Klipper config (config_new) from the stock Infimech TX
# config. Used by step 3 (3_klipper.sh).
#
#   make_config.py --home H --old DIR --templates DIR --out DIR --diff FILE
#
# Reads DIR (the stock printer_data/config) and writes a complete new config
# folder to --out. Nothing in --old is changed.
#
# Before building, it checks that the HARDWARE part of the stock config is
# the one these templates were made from (#OCTO-v1.0.20-20250430 /
# #OCTO-printer.cfg-v1.0.1-20240925): every section of printer_config.cfg
# except the macros ([gcode_macro ...], [delayed_gcode ...]), compared without
# comments, apart from the few values that may differ per printer (MCU
# serial, bed heater check time, save_variables file). Macros are not
# compared: the mainline config replaces all of them, so your own macro
# changes don't matter (they stay in the backup, config_stock).
# A different hardware part means a different vendor config: it stops,
# writes a diff, and builds nothing.
# printer.cfg (the short main file) is checked section by section: only the
# stock sections are allowed (includes, virtual_sdcard, mcu rpi,
# smart_effector, heater_bed, and optionally extruder PID and an empty
# skew_correction). TEST_SPEED.cfg is optional.
# Carried over from your config: the SAVE_CONFIG block of printer.cfg (your
# calibration), z_offset, bed PID and (if set there) extruder PID from
# printer.cfg, the nozzle wipe depths.
#
# Exit codes: 0 built, 2 refused (nothing built), 1 unexpected error.
import argparse
import difflib
import os
import re
import shutil
import sys

MARKER = '#*# <---------------------- SAVE_CONFIG ---------------------->'
CLEAN_FILES = ['printer_config.cfg', 'fans_stock.cfg', 'fans_mainline.cfg',
               'macros.cfg', 'screen.cfg', 'infimech.cfg']
SAVEVARS_OK = ['/klipper/config/saved_variables.cfg',
               '/printer_data/saved_variables.cfg']
# carried over unchanged; must exist (printer.cfg includes them)
REQUIRED = ['fluidd.cfg', 'timelapse.cfg', 'init.cfg']
# carried over if present; the include line is left out if it is missing
OPTIONAL = ['TEST_SPEED.cfg']
# replaced or no longer used: left out of the new folder (still in backup)
DROP = ['printer.cfg', 'printer_config.cfg', 'KAMP_Settings.cfg', 'KAMP']
DROP_RE = re.compile(r'^printer_config\.cfg\.bak-')

SAVE_CONFIG_MACROS = [
    ['[gcode_macro SAVE_CONFIG]', 'rename_existing: SAVE_CONFIG_BASE',
     'gcode:', '', '    SAVE_CONFIG_BASE', '    RESTART'],
    ['[gcode_macro SAVE_CONFIG]', 'rename_existing: SAVE_CONFIG_BASE',
     'gcode:',
     '    {% if printer.print_stats.state in ["printing", "paused"] %}',
     '        M118 SAVE_CONFIG skipped during a print (it would restart Klipper)',
     '    {% else %}',
     '        SAVE_CONFIG_BASE',
     '    {% endif %}'],
]


class Refused(Exception):
    pass


def read_lines(path):
    with open(path, 'rb') as f:
        data = f.read()
    text = data.decode('utf-8')
    return [l.rstrip() for l in text.replace('\r\n', '\n').split('\n')]


def strip_tail(lines):
    lines = list(lines)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def section_of(lines):
    """Yield (index, current section name) for each line."""
    sec = None
    for i, l in enumerate(lines):
        m = re.match(r'^\[([^\]]+)\]', l)
        if m:
            sec = m.group(1).strip()
        yield i, sec


def normalize_printer_config(lines, found):
    out = list(lines)
    serials, gains, wipe1, wipe2, savevars = [], [], [], [], []
    for i, sec in section_of(lines):
        l = lines[i]
        if sec == 'mcu':
            m = re.match(r'^serial\s*:\s*(\S+)$', l)
            if m:
                serials.append(m.group(1))
                out[i] = 'serial:@SERIAL@'
                continue
        if sec == 'verify_heater heater_bed':
            m = re.match(r'^check_gain_time\s*:\s*(\d+)$', l)
            if m:
                gains.append(m.group(1))
                out[i] = 'check_gain_time:@BEDGAIN@'
                continue
        if sec == 'save_variables':
            m = re.match(r'^filename\s*[:=]\s*(\S+)$', l)
            if m:
                savevars.append(m.group(1))
                out[i] = 'filename:@SAVEVARS@'
                continue
        m = re.match(r'^(\s*G1 X18\.5 Y-3\.5 Z)(-0\.\d+)( F200)$', l)
        if m:
            wipe1.append(m.group(2))
            out[i] = m.group(1) + '@WIPE1@' + m.group(3)
            continue
        m = re.match(r'^(\s*G1 Z)(-0\.\d+)$', l)
        if m:
            wipe2.append(m.group(2))
            out[i] = m.group(1) + '@WIPE2@'
            continue
    # SAVE_CONFIG macro: either the stock one or the 2b version
    starts = [i for i, l in enumerate(out) if l == '[gcode_macro SAVE_CONFIG]']
    if len(starts) == 1:
        s = starts[0]
        e = s + 1
        while e < len(out) and not out[e].startswith('['):
            e += 1
        body = out[s:e]
        while body and not body[-1].strip():
            body.pop()
        for n, variant in enumerate(SAVE_CONFIG_MACROS):
            if body == variant:
                found['save_config_macro'] = ('stock', 'skip-during-print')[n]
                out[s:s + len(body)] = ['@SAVE_CONFIG_MACRO@']
                break
    found.update(serials=serials, gains=gains, wipe1=wipe1, wipe2=wipe2,
                 savevars=savevars)
    return strip_tail(out)


# printer.cfg main part: allowed sections and options. A value of None means
# "any value, carried over"; a string is the only value allowed.
MAIN_INCLUDES_REQUIRED = {'fluidd.cfg', 'timelapse.cfg', 'printer_config.cfg'}
MAIN_INCLUDES_OPTIONAL = {'test_speed.cfg'}
MAIN_SECTIONS = {
    'virtual_sdcard': {'path': None, 'on_error_gcode': 'CANCEL_PRINT'},
    'mcu rpi': {'serial': '/tmp/klipper_host_mcu'},
    'smart_effector': {'z_offset': None},
    'heater_bed': {'control': 'pid', 'pid_kp': None, 'pid_ki': None,
                   'pid_kd': None},
    'extruder': {'control': 'pid', 'pid_kp': None, 'pid_ki': None,
                 'pid_kd': None},
    'skew_correction': {},
}
NUM_RE = re.compile(r'^-?[0-9]+(\.[0-9]+)?$')


def check_printer_main(lines, diff_path):
    """Check the main part of printer.cfg; return {section: {option: value}}."""
    vals, bad, includes, sec = {}, [], set(), None
    for n, raw in enumerate(lines, 1):
        l = re.sub(r'\s+[#;].*$', '', raw).strip()
        if not l or l.startswith(('#', ';')):
            continue
        if raw[0] in ' \t':
            bad.append((n, raw, 'unexpected indented line'))
            continue
        m = re.match(r'^\[include\s+([^\]]+)\]$', l)
        if m:
            name = m.group(1).strip()
            if name.lower() not in {x.lower() for x in
                                    MAIN_INCLUDES_REQUIRED} | MAIN_INCLUDES_OPTIONAL:
                bad.append((n, raw, 'unexpected include'))
            includes.add(name.lower())
            sec = None
            continue
        m = re.match(r'^\[([^\]]+)\]$', l)
        if m:
            sec = ' '.join(m.group(1).lower().split())
            if sec not in MAIN_SECTIONS:
                bad.append((n, raw, 'unexpected section'))
                sec = '!'
            elif sec in vals:
                bad.append((n, raw, 'section appears twice'))
            vals.setdefault(sec, {})
            continue
        if sec == '!':
            continue
        m = re.match(r'^([A-Za-z0-9_]+)\s*[:=]\s*(.*)$', l)
        if not m or sec is None:
            bad.append((n, raw, 'unexpected line'))
            continue
        key, val = m.group(1).lower(), m.group(2).strip()
        allowed = MAIN_SECTIONS[sec]
        if key not in allowed:
            bad.append((n, raw, 'unexpected option in [%s]' % sec))
        elif allowed[key] is not None and val.lower() != allowed[key].lower():
            bad.append((n, raw, 'expected %s: %s' % (key, allowed[key])))
        elif allowed[key] is None and key != 'path' and not NUM_RE.match(val):
            bad.append((n, raw, 'not a number'))
        else:
            vals[sec][key] = val
    for name in sorted(MAIN_INCLUDES_REQUIRED):
        if name.lower() not in includes:
            bad.append((0, '[include %s]' % name, 'missing'))
    for sec, need in (('virtual_sdcard', ['path']), ('mcu rpi', ['serial']),
                      ('smart_effector', ['z_offset']),
                      ('heater_bed', ['control', 'pid_kp', 'pid_ki', 'pid_kd'])):
        for k in need:
            if k not in vals.get(sec, {}):
                bad.append((0, '[%s] %s' % (sec, k), 'missing'))
    ext = vals.get('extruder', {})
    if ext and set(ext) != {'control', 'pid_kp', 'pid_ki', 'pid_kd'}:
        bad.append((0, '[extruder] %s' % ' '.join(sorted(ext)),
                    'expected control, pid_Kp, pid_Ki, pid_Kd together'))
    if bad:
        with open(diff_path, 'a') as f:
            f.write('printer.cfg (main part, above SAVE_CONFIG): lines not '
                    'in the stock file\n')
            for n, raw, why in bad:
                f.write('  line %s: %s    <- %s\n' % (n or '-', raw.strip(), why))
        raise Refused("printer.cfg has lines that are not in the stock file "
                      "(see %s)" % (diff_path,))
    return vals


MACRO_SECTIONS = ('gcode_macro', 'delayed_gcode')


def hardware_only(lines):
    """Lines outside macro sections, without comments and blank lines."""
    out, skip = [], False
    for l in lines:
        m = re.match(r'^\[([^\]]+)\]', l)
        if m:
            skip = m.group(1).strip().lower().startswith(MACRO_SECTIONS)
        if skip or not l.strip() or l.lstrip().startswith(('#', ';')):
            continue
        out.append(re.sub(r'\s+[#;].*$', '', l).rstrip())
    return out


def compare(name, have, expected_path, diff_path, filt=None):
    want = strip_tail(read_lines(expected_path))
    if filt:
        have, want = filt(have), filt(want)
    if have == want:
        return
    diff = difflib.unified_diff(want, have, 'expected/' + name,
                                'yours/' + name, lineterm='')
    with open(diff_path, 'a') as f:
        f.write('\n'.join(diff) + '\n')
    raise Refused("%s differs from what this package expects (see %s)"
                  % (name, diff_path))


def wipe_value(found, key, default):
    # the nozzle wipe depth of the stock clean_nozzle_position macro; if the
    # macro was changed (or copied) and the values disagree: the stock value
    vals = sorted(set(v for v in found[key] if re.match(r'^-0\.\d+$', v)))
    if len(vals) == 1 and -0.5 <= float(vals[0]) <= 0:
        return vals[0]
    print("note: nozzle wipe depth %s: found %s, using the stock %s"
          % (key, vals or 'none', default))
    return default


def one_value(found, key, what, allowed=None):
    vals = sorted(set(found[key]))
    if len(vals) != 1:
        raise Refused("expected one %s, found %s" % (what, vals or 'none'))
    if allowed is not None and vals[0] not in allowed:
        raise Refused("unexpected %s %s" % (what, vals[0]))
    return vals[0]


def parse_cfg_options(lines):
    """(section, option) pairs set in a Klipper config file."""
    pairs = set()
    sec = None
    for l in lines:
        if not l.strip() or l.lstrip().startswith(('#', ';')):
            continue
        m = re.match(r'^\[([^\]]+)\]', l)
        if m:
            sec = m.group(1).strip().lower()
            continue
        if l[0] in ' \t' or sec is None:
            continue
        m = re.match(r'^([^:=]+?)\s*[:=]', l)
        if m:
            pairs.add((sec, m.group(1).strip().lower()))
    return pairs


def autosave_options(block):
    pairs = set()
    sec = None
    for l in block:
        if not l.startswith('#*#'):
            continue
        m = re.match(r'^ ?\[([^\]]+)\]', l[3:])
        if m:
            sec = m.group(1).strip().lower()
            continue
        # "#*# key = value"; deeper-indented lines continue a value
        m = re.match(r'^ ?([A-Za-z0-9_]+)\s*=', l[3:])
        if m and sec:
            pairs.add((sec, m.group(1).lower()))
    return pairs


def build(args):
    home = args.home.rstrip('/')
    old, tpl, out = args.old, args.templates, args.out
    diff_path = args.diff
    if os.path.exists(diff_path):
        os.remove(diff_path)
    if os.path.exists(out):
        raise Refused("%s already exists" % (out,))
    for f in REQUIRED + ['printer.cfg', 'printer_config.cfg']:
        if not os.path.isfile(os.path.join(old, f)):
            raise Refused("%s is missing from %s" % (f, old))
    for f in CLEAN_FILES + ['printer.cfg']:
        if not os.path.isfile(os.path.join(tpl, f)):
            raise Refused("template %s is missing" % (f,))

    found = {}
    # --- printer_config.cfg
    pc = normalize_printer_config(
        read_lines(os.path.join(old, 'printer_config.cfg')), found)
    compare('printer_config.cfg', pc,
            os.path.join(tpl, 'expected_printer_config.txt'), diff_path,
            hardware_only)
    serial = one_value(found, 'serials', 'MCU serial')
    if not serial.startswith('/dev/serial/by-id/usb-Klipper_stm32f072xb_'):
        raise Refused("unexpected MCU serial %s" % (serial,))
    gain = one_value(found, 'gains', 'bed check_gain_time', ['60', '400'])
    wipe1 = wipe_value(found, 'wipe1', '-0.15')
    wipe2 = wipe_value(found, 'wipe2', '-0.2')
    savevars = one_value(found, 'savevars', 'save_variables file')
    if savevars not in [home + p for p in SAVEVARS_OK]:
        raise Refused("save_variables file is %s, expected one of %s"
                      % (savevars, [home + p for p in SAVEVARS_OK]))

    # --- printer.cfg: main part checked, SAVE_CONFIG block carried over
    pl = read_lines(os.path.join(old, 'printer.cfg'))
    if pl.count(MARKER) > 1:
        raise Refused("printer.cfg has more than one SAVE_CONFIG block")
    if MARKER in pl:
        k = pl.index(MARKER)
        main, block = pl[:k], strip_tail(pl[k:])
    else:
        main, block = pl, []
    mv = check_printer_main(main, diff_path)
    bed = mv['heater_bed']
    cal = {'@ZOFFSET@': mv['smart_effector']['z_offset'],
           '@BED_KP@': bed['pid_kp'], '@BED_KI@': bed['pid_ki'],
           '@BED_KD@': bed['pid_kd']}
    gcodes = mv['virtual_sdcard']['path']
    if gcodes.rstrip('/') != home + '/printer_data/gcodes':
        raise Refused("virtual_sdcard path is %s, expected %s"
                      % (gcodes, home + '/printer_data/gcodes'))
    # extruder PID: in the SAVE_CONFIG block (after PID_CALIBRATE) or in the
    # main part (factory value); the main-part value is carried over only if
    # the block has none
    block_ext = {k for s_, k in autosave_options(block) if s_ == 'extruder'}
    ext = mv.get('extruder', {})
    if {'pid_kp', 'pid_ki', 'pid_kd'} <= block_ext:
        ext_pid, ext_src = '', 'SAVE_CONFIG block'
    elif ext:
        ext_pid = ('\n[extruder]\ncontrol: pid\npid_Kp: %s\npid_Ki: %s\n'
                   'pid_Kd: %s\n' % (ext['pid_kp'], ext['pid_ki'], ext['pid_kd']))
        ext_src = 'printer.cfg %s %s %s' % (ext['pid_kp'], ext['pid_ki'],
                                            ext['pid_kd'])
    else:
        raise Refused("no extruder PID found (neither in printer.cfg nor in "
                      "its SAVE_CONFIG block)")
    optional = [f for f in OPTIONAL if os.path.isfile(os.path.join(old, f))]

    # --- render the clean files
    values = {'@H@': home, '@MCU_SERIAL@': serial,
              '@WIPE1@': wipe1, '@WIPE2@': wipe2}
    values.update(cal)
    values['@EXTRUDER_PID@'] = ext_pid
    rendered = {}
    for f in CLEAN_FILES + ['printer.cfg']:
        with open(os.path.join(tpl, f)) as fh:
            text = fh.read()
        for k, v in values.items():
            text = text.replace(k, v)
        left = re.findall(r'@[A-Z0-9_]+@', text)
        if left:
            raise Refused("template %s: unfilled %s" % (f, left))
        rendered[f] = text
    for f in OPTIONAL:
        if f not in optional:
            rendered['printer.cfg'] = rendered['printer.cfg'].replace(
                '[include %s]\n' % f, '')
    if block:
        rendered['printer.cfg'] = (rendered['printer.cfg'].rstrip('\n')
                                   + '\n\n' + '\n'.join(block) + '\n')

    # --- the SAVE_CONFIG block must not set options that live in an
    # included file (SAVE_CONFIG would refuse to save later)
    included = set()
    for f in CLEAN_FILES:
        if f == 'fans_mainline.cfg':
            continue
        included |= parse_cfg_options(rendered[f].split('\n'))
    for f in REQUIRED + optional:
        included |= parse_cfg_options(read_lines(os.path.join(old, f)))
    clash = sorted(autosave_options(block) & included)
    if clash:
        raise Refused("SAVE_CONFIG block sets options that are in included "
                      "files: %s" % (clash,))

    # --- write the new folder
    os.makedirs(out)
    kept, dropped = [], []
    for name in sorted(os.listdir(old)):
        src = os.path.join(old, name)
        if name in DROP or DROP_RE.match(name):
            dropped.append(name)
            continue
        dst = os.path.join(out, name)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        elif os.path.isdir(src):
            shutil.copytree(src, dst, symlinks=True)
        else:
            shutil.copy2(src, dst)
        kept.append(name)
    for f, text in rendered.items():
        with open(os.path.join(out, f), 'w') as fh:
            fh.write(text)
        os.chmod(os.path.join(out, f), 0o644)

    print("MCU serial:            %s (step 4 sets the new one)" % (serial,))
    print("saved variables:       %s" % (savevars,))
    print("bed check_gain_time:   %s -> 60%s" % (
        gain, '' if gain == '60' else '  (the value recommended earlier)'))
    print("wipe depths kept:      %s and %s mm" % (wipe1, wipe2))
    print("z_offset, bed PID:     %s / %s %s %s" % (cal['@ZOFFSET@'], cal['@BED_KP@'],
                                                    cal['@BED_KI@'], cal['@BED_KD@']))
    print("extruder PID:          from the %s" % (ext_src,))
    print("SAVE_CONFIG block:     %d lines carried over" % (len(block),))
    print("carried over as is:    %s" % (' '.join(kept),))
    print("left out (in backup):  %s" % (' '.join(dropped),))
    print("new files:             %s" % (' '.join(sorted(rendered)),))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--home', required=True)
    ap.add_argument('--old', required=True)
    ap.add_argument('--templates', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--diff', required=True)
    ap.add_argument('--make-expected', action='store_true',
                    help='write expected_*.txt from --old (package build only)')
    args = ap.parse_args()
    if args.make_expected:
        found = {}
        pc = normalize_printer_config(
            read_lines(os.path.join(args.old, 'printer_config.cfg')), found)
        for name, lines in (('expected_printer_config.txt', pc),):
            with open(os.path.join(args.templates, name), 'w') as f:
                f.write('\n'.join(lines) + '\n')
        print(found)
        return 0
    try:
        build(args)
    except Refused as e:
        print("NOT BUILT: %s" % (e,))
        if os.path.isdir(args.out) and not os.listdir(args.out):
            os.rmdir(args.out)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
