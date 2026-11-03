#!/usr/bin/env python3
"""Extract a single member from the (1.2 GB) Godot export templates zip over HTTP.

Usage: fetch_template.py <tpz-url> <member-name> <output-path>
Only the bytes for the requested member are downloaded (HTTP range requests).
"""
import struct, sys, zlib, os, time, urllib.request

UA = {'User-Agent': 'abuela-port/1.0'}


def get_range(url, start, end, retries=5):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={**UA, 'Range': 'bytes=%d-%d' % (start, end)})
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.read()
        except Exception as exc:                       # noqa: BLE001
            if attempt == retries - 1:
                raise
            print('  retry %d: %s' % (attempt + 1, exc))
            time.sleep(2 + attempt * 2)


def remote_size(url):
    req = urllib.request.Request(url, method='HEAD', headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers['Content-Length'])


def read_directory(url):
    total = remote_size(url)
    tail_start = max(0, total - 100000)
    tail = get_range(url, tail_start, total - 1)
    idx = tail.rfind(b'PK\x05\x06')
    if idx < 0:
        raise SystemExit('no end-of-central-directory record')
    eocd = tail[idx:idx + 22]
    n_entries, cd_size, cd_off = struct.unpack('<HII', eocd[10:20])
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
        z = tail.rfind(b'PK\x06\x06')
        z64 = tail[z:z + 56]
        cd_size, cd_off = struct.unpack('<QQ', z64[40:56])
    cd = get_range(url, cd_off, cd_off + cd_size - 1)
    members, i = {}, 0
    while i < len(cd) - 4 and cd[i:i + 4] == b'PK\x01\x02':
        (ver, need, flags, method, mtime, mdate, crc, csize, usize,
         nlen, elen, clen, dstart, iattr, eattr, off) = struct.unpack('<6H3I5H2I', cd[i + 4:i + 46])
        name = cd[i + 46:i + 46 + nlen].decode('utf-8')
        extra = cd[i + 46 + nlen:i + 46 + nlen + elen]
        if csize == 0xFFFFFFFF or off == 0xFFFFFFFF:
            j, vals = 0, []
            while j < len(extra) - 4:
                hid, hsz = struct.unpack('<HH', extra[j:j + 4])
                if hid == 1:
                    vals = list(struct.unpack('<%dQ' % (hsz // 8), extra[j + 4:j + 4 + hsz]))
                j += 4 + hsz
            k = 0
            if usize == 0xFFFFFFFF:
                k += 1
            if csize == 0xFFFFFFFF:
                csize = vals[k]; k += 1
            if off == 0xFFFFFFFF:
                off = vals[k]
        members[name] = (off, csize, method)
        i += 46 + nlen + elen + clen
    return members


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    url, member, out_path = sys.argv[1:4]
    members = read_directory(url)
    if member not in members:
        raise SystemExit('member not in archive: ' + member)
    off, csize, method = members[member]
    lh = get_range(url, off, off + 29)
    if lh[:4] != b'PK\x03\x04':
        raise SystemExit('bad local header')
    nlen, elen = struct.unpack('<HH', lh[26:30])
    data_off = off + 30 + nlen + elen
    print('  fetching %s (%d bytes compressed)' % (member, csize))
    data = get_range(url, data_off, data_off + csize - 1)
    if method == 8:
        data = zlib.decompress(data, -15)
    os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
    with open(out_path, 'wb') as f:
        f.write(data)
    print('  -> %s (%d bytes)' % (out_path, len(data)))


if __name__ == '__main__':
    main()
