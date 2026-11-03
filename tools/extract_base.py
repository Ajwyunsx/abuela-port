#!/usr/bin/env python3
"""Extract the untouched resource pack out of the original Windows build.

    ABUELA_EXE=/path/to/ABUELA.exe python3 tools/extract_base.py

Writes assets/game_base.pck, which is everything the portable build needs.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import pck

EXE = os.environ.get('ABUELA_EXE', os.path.join(ROOT, 'ABUELA.exe'))


def find_pck_offset(path):
    with open(path, 'rb') as f:
        data = f.read()
    idx = data.rfind(b'GDPC')
    while idx != -1:
        if int.from_bytes(data[idx + 4:idx + 8], 'little') == 4:
            return idx
        idx = data.rfind(b'GDPC', 0, idx)
    raise SystemExit('no embedded PCK found in ' + path)


def main():
    if not os.path.exists(EXE):
        raise SystemExit('game executable not found: %s\nset ABUELA_EXE' % EXE)
    off = find_pck_offset(EXE)
    print('PCK found at 0x%x' % off)
    p = pck.Pck.from_exe(EXE, off)
    with open(EXE, 'rb') as f:
        f.seek(off)
        hdr = f.read(pck.HEADER_SIZE)
        _fb, dir_off = struct.unpack('<2Q', hdr[24:40])
        f.seek(off + dir_off)
        count = struct.unpack('<I', f.read(4))[0]
        for _ in range(count):
            ln = struct.unpack('<I', f.read(4))[0]
            f.read(ln + 16 + 16 + 4)
        f.seek(f.tell())
        p.trailer = f.read()
    out = os.path.join(ROOT, 'assets', 'game_base.pck')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    size = p.write(out)
    icon = p.files.get('icon.png')
    if icon:
        with open(os.path.join(ROOT, 'assets', 'icon.png'), 'wb') as f:
            f.write(icon)
    print('wrote %s: %d bytes, %d files' % (out, size, len(p.files)))


if __name__ == '__main__':
    main()
