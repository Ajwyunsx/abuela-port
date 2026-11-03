"""Patch Godot 4.x binary project settings (ECFG).

Layout (verified on ABUELA.exe project.binary):
  "ECFG" | u32 count | entries...
  entry := u32 key_len | key bytes (no padding) | u32 value_len | value block
  value block := u32 variant_type | payload   (block padded to 4 bytes)
  String variant := u32 type(4) | u32 len | utf8 bytes | pad to 4
"""
import struct

def enc_string(s: str) -> bytes:
    b = s.encode('utf-8')
    pad = (4 - len(b) % 4) % 4
    return struct.pack('<II', 4, len(b)) + b + b'\x00' * pad

def enc_bool(v: bool) -> bytes:
    return struct.pack('<II', 1, 1 if v else 0)

def parse(data: bytes):
    assert data[:4] == b'ECFG'
    count = struct.unpack_from('<I', data, 4)[0]
    pos = 8
    entries = []
    for _ in range(count):
        klen = struct.unpack_from('<I', data, pos)[0]; pos += 4
        key = data[pos:pos+klen].decode('utf-8'); pos += klen
        vlen = struct.unpack_from('<I', data, pos)[0]; pos += 4
        val = data[pos:pos+vlen]; pos += vlen
        entries.append((key, val))
    assert pos == len(data), (pos, len(data))
    return entries

def build(entries) -> bytes:
    out = bytearray(b'ECFG')
    out += struct.pack('<I', len(entries))
    for key, val in entries:
        kb = key.encode('utf-8')
        out += struct.pack('<I', len(kb)) + kb
        out += struct.pack('<I', len(val)) + val
    return bytes(out)

def get(entries, key):
    for k, v in entries:
        if k == key:
            return v
    return None

def set_value(entries, key, newv):
    for i, (k, v) in enumerate(entries):
        if k == key:
            entries[i] = (k, newv)
            return True
    entries.append((key, newv))
    return False

def set_string(entries, key, value):
    newv = enc_string(value)
    for i, (k, v) in enumerate(entries):
        if k == key:
            entries[i] = (k, newv)
            return True
    entries.append((key, newv))
    return False

def decode_string(v: bytes):
    if len(v) < 8:
        return None
    t, ln = struct.unpack('<II', v[:8])
    if t != 4:
        return None
    return v[8:8+ln].decode('utf-8', 'replace')

if __name__ == '__main__':
    import sys
    e = parse(open(sys.argv[1], 'rb').read())
    print('entries', len(e))
    for k, v in e:
        if k.startswith('input/') or k.startswith('autoload/'):
            print(k, '=>', (decode_string(v) or v[:40].hex(' ')))
