#!/usr/bin/env python3
"""Build the patched ABUELA resource pack (project settings + touch overlay).

Input : the original ABUELA.exe (its embedded PCK is read in place)
Output: out/game_touch.pck      -- pack with the touch overlay, for the APK
        out/game_selftest.pck   -- same plus the automated self test
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import pck
import ecfg_patch

OVERLAY_PATH = os.path.join(ROOT, 'touch', 'touch_controls.gd')
SELFTEST_PATH = os.path.join(ROOT, 'touch', 'selftest.gd')
# The original game is either the Windows .exe (embedded PCK) or an already
# extracted base pack. ABUELA_BASE overrides both.
BASE = os.environ.get('ABUELA_BASE') or os.environ.get('ABUELA_EXE')
if not BASE:
    for cand in (os.path.join(ROOT, 'ABUELA.exe'),
                 os.path.join(ROOT, 'assets', 'game_base.pck'),
                 '/root/ABUELA.exe'):
        if os.path.exists(cand):
            BASE = cand
            break
if not BASE or not os.path.exists(BASE):
    raise SystemExit('no base game found: pass ABUELA_BASE=/path/to/ABUELA.exe '
                     'or ABUELA_BASE=/path/to/game_base.pck')
PCK_OFF = int(os.environ.get('ABUELA_PCK_OFFSET', '0'), 0) or None
OUT_DIR = os.path.join(ROOT, 'out')

OVERLAY = open(OVERLAY_PATH, 'rb').read()
SELFTEST = open(SELFTEST_PATH, 'rb').read()


def find_pck_offset(exe_path):
    """Locate the embedded PCK header (last 'GDPC' before the pack)."""
    with open(exe_path, 'rb') as f:
        data = f.read()
    idx = data.rfind(b'GDPC')
    while idx != -1:
        # a real header is followed by the pack format version (4)
        try:
            if int.from_bytes(data[idx + 4:idx + 8], 'little') == 4:
                return idx
        except Exception:
            pass
        idx = data.rfind(b'GDPC', 0, idx)
    raise SystemExit('could not locate the embedded PCK in %s' % exe_path)


def pack_offset():
    if PCK_OFF is not None:
        return PCK_OFF
    return find_pck_offset(EXE)


def load_base():
    """Load the original pack plus whatever follows its directory table."""
    import struct
    is_pck = BASE.lower().endswith('.pck')
    off = 0 if is_pck else pack_offset()
    p = pck.Pck.from_exe(BASE, off)
    with open(BASE, 'rb') as f:
        f.seek(off)
        hdr = f.read(pck.HEADER_SIZE)
        _file_base, dir_off = struct.unpack('<2Q', hdr[24:40])
        f.seek(off + dir_off)
        count = struct.unpack('<I', f.read(4))[0]
        for _ in range(count):
            ln = struct.unpack('<I', f.read(4))[0]
            f.read(ln + 16 + 16 + 4)
        dir_end = f.tell()
        p.trailer = f.read()
    return p


def build_variant(out_pck, emulate_touch_from_mouse=False, selftest=False):
    p = load_base()

    entries = ecfg_patch.parse(p.get_file('project.binary'))
    ecfg_patch.set_string(entries, 'autoload/TouchControls', '*res://touch/touch_controls.gd')
    ecfg_patch.set_value(entries, 'input_devices/pointing/emulate_mouse_from_touch',
                         ecfg_patch.enc_bool(False))
    ecfg_patch.set_value(entries, 'input_devices/pointing/emulate_touch_from_mouse',
                         ecfg_patch.enc_bool(emulate_touch_from_mouse))
    if selftest:
        ecfg_patch.set_string(entries, 'autoload/SelfTest', '*res://touch/selftest.gd')
    p.set_file('project.binary', ecfg_patch.build(entries))
    p.set_file('touch/touch_controls.gd', OVERLAY)
    if selftest:
        p.set_file('touch/selftest.gd', SELFTEST)

    os.makedirs(os.path.dirname(out_pck), exist_ok=True)
    n = p.write(out_pck)
    print('wrote %s: %d bytes, %d files' % (out_pck, n, len(p.files)))
    return p


if __name__ == '__main__':
    build_variant(os.path.join(OUT_DIR, 'game_touch.pck'), False)
    build_variant(os.path.join(OUT_DIR, 'game_selftest.pck'), False, selftest=True)
    build_variant(os.path.join(OUT_DIR, 'game_touch_test.pck'), True)
