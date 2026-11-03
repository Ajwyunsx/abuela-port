"""Godot 4.x PCK (pack) reader/writer, verified against ABUELA.exe."""
import struct, hashlib, os, sys

HEADER_SIZE = 112
PACK_MAGIC = b'GDPC'

class Pck:
    def __init__(self, pack_format_version=4, ver=(4,7,2), flags=2):
        self.pack_format_version = pack_format_version
        self.ver = ver
        self.flags = flags
        self.files = {}          # path -> bytes
        self.order = []          # preserve original order
        self.trailer = b''

    # ---------- reading ----------
    @classmethod
    def from_exe(cls, exe_path, pck_offset=0):
        f = open(exe_path, 'rb')
        f.seek(pck_offset)
        hdr = f.read(HEADER_SIZE)
        assert hdr[:4] == PACK_MAGIC, hdr[:4]
        pfv, vmaj, vmin, vpatch, flags = struct.unpack('<5I', hdr[4:24])
        file_base, dir_off = struct.unpack('<2Q', hdr[24:40])
        obj = cls(pfv, (vmaj, vmin, vpatch), flags)
        f.seek(pck_offset + dir_off)
        count = struct.unpack('<I', f.read(4))[0]
        entries = []
        for _ in range(count):
            ln = struct.unpack('<I', f.read(4))[0]
            path = f.read(ln).decode('utf-8').rstrip('\x00')
            off, size = struct.unpack('<2Q', f.read(16))
            f.read(16)
            f.read(4)
            entries.append((path, off, size))
        data_start = pck_offset + file_base
        for path, off, size in entries:
            f.seek(data_start + off)
            obj.files[path] = f.read(size)
            obj.order.append(path)
        # trailer = bytes between end of directory and end of pack region
        dir_end = f.tell()
        obj.trailer = b''
        obj._dir_end = dir_end
        obj._pck_offset = pck_offset
        obj._file_base = file_base
        f.close()
        return obj

    @classmethod
    def from_pck(cls, pck_path):
        """Read a standalone .pck file (header at offset 0, no executable)."""
        return cls.from_exe(pck_path, 0)

    # ---------- writing ----------
    def write(self, out_path):
        out = bytearray()
        out += PACK_MAGIC
        out += struct.pack('<5I', self.pack_format_version, *self.ver, self.flags)
        out += struct.pack('<Q', HEADER_SIZE)      # file_base
        dir_off_pos = len(out)
        out += struct.pack('<Q', 0)               # dir_offset placeholder
        out += b'\x00' * (HEADER_SIZE - len(out))
        # file data
        offsets = {}
        for path in self.order:
            if path not in self.files:
                continue
            offsets[path] = len(out) - HEADER_SIZE
            out += self.files[path]
        # directory
        dir_off = len(out)
        struct.pack_into('<Q', out, dir_off_pos, dir_off)
        count = sum(1 for p in self.order if p in self.files)
        out += struct.pack('<I', count)
        for path in self.order:
            if path not in self.files:
                continue
            data = self.files[path]
            pb = path.encode('utf-8')
            out += struct.pack('<I', len(pb)) + pb
            out += struct.pack('<QQ', offsets[path], len(data))
            out += hashlib.md5(data).digest()
            out += struct.pack('<I', 0)
        out += self.trailer
        with open(out_path, 'wb') as f:
            f.write(out)
        return len(out)

    def set_file(self, path, data):
        if path not in self.files:
            self.order.append(path)
        self.files[path] = data

    def get_file(self, path):
        return self.files[path]

if __name__ == '__main__':
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    exe = os.environ.get('ABUELA_EXE', os.path.join(os.path.dirname(here), 'ABUELA.exe'))
    off = int(os.environ.get('ABUELA_PCK_OFFSET', '0'), 0)
    p = Pck.from_exe(exe, off)
    print('files:', len(p.files))
