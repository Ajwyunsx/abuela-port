#!/usr/bin/env python3
"""Package ABUELA (Godot 4.7.2) into an installable, signed Android APK.

Strategy (no aapt2 needed):
  * start from the official Godot 4.7.2 android_release.apk template
  * replace the launcher icon resources (same file names / formats)
  * patch the app label in resources.arsc (equal length replacement)
  * inject the game resources the way the Godot exporter does:
        assets/<path>            one file per packed resource
        assets/assets.sparsepck  pack header + directory (sparse bundle)
  * keep the native libs uncompressed and page aligned, sign with apksigner
"""
import os, sys, struct, hashlib, subprocess, zipfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TEMPLATE_APK = os.environ.get('GODOT_ANDROID_TEMPLATE',
                              os.path.join(ROOT, 'templates', 'android_release.apk'))
OUT_DIR = os.path.join(ROOT, 'out')
WORK = os.path.join(ROOT, 'work')
KEYSTORE = os.environ.get('ABUELA_KEYSTORE', os.path.join(WORK, 'abuela.keystore'))
KS_PASS = os.environ.get('ABUELA_KEYSTORE_PASS', 'abuela2026')
KS_ALIAS = os.environ.get('ABUELA_KEYSTORE_ALIAS', 'abuela')
LABEL = 'ABUELA v3.0.9 Port'          # must stay 18 chars (== "godot-project-name")
ICON_PNG = os.environ.get('ABUELA_ICON', os.path.join(ROOT, 'assets', 'icon.png'))
_DEFAULT_ICON = os.path.join(ROOT, 'assets', 'icon.png')

PACK_MAGIC = 0x43504447
PACK_VERSION = 4
PACK_REL_FILEBASE = 1 << 1
PACK_SPARSE_BUNDLE = 1 << 2
ALIGN = 4096

STORED_EXT = ('.so', '.png', '.webp', '.jpg', '.jpeg', '.ogg', '.ogv', '.mp3', '.wav', '.ctex', '.m4a', '.ttf')
ICON_FILES = ('icon.webp', 'icon_foreground.webp', 'icon_background.webp', 'icon_monochrome.webp')


# ---------------------------------------------------------------- pck

def read_pck(path):
    f = open(path, 'rb')
    hdr = f.read(112)
    assert struct.unpack('<I', hdr[:4])[0] == PACK_MAGIC, 'not a pack'
    version, vmaj, vmin, vpatch, flags = struct.unpack('<5I', hdr[4:24])
    file_base, dir_off = struct.unpack('<2Q', hdr[24:40])
    assert version == PACK_VERSION, version
    f.seek(dir_off)
    count = struct.unpack('<I', f.read(4))[0]
    entries = []
    for _ in range(count):
        ln = struct.unpack('<I', f.read(4))[0]
        p = f.read(ln).rstrip(b'\x00').decode('utf-8')
        ofs, size = struct.unpack('<2Q', f.read(16))
        f.read(16)
        f.read(4)
        entries.append((p, ofs, size))
    out = []
    for p, ofs, size in entries:
        f.seek(file_base + ofs)
        out.append((p, f.read(size)))
    f.close()
    return out


def sparse_metadata(files):
    head = bytearray()
    head += struct.pack('<I', PACK_MAGIC)
    head += struct.pack('<5I', PACK_VERSION, 4, 7, 2, PACK_REL_FILEBASE | PACK_SPARSE_BUNDLE)
    head += struct.pack('<Q', 0)        # file base (unused for sparse bundles)
    head += struct.pack('<Q', 104)      # directory offset
    head += b'\x00' * 64               # reserved
    assert len(head) == 104
    body = bytearray()
    body += struct.pack('<I', len(files))
    for p, data in files:
        pb = p.encode('utf-8')
        pad = (4 - len(pb) % 4) % 4
        body += struct.pack('<I', len(pb) + pad)
        body += pb + b'\x00' * pad
        body += struct.pack('<Q', 0)
        body += struct.pack('<Q', len(data))
        body += hashlib.md5(data).digest()
        body += struct.pack('<I', 0)
    return bytes(head) + bytes(body)


# ---------------------------------------------------------------- icons

def build_icons(icon_bytes=None):
    from PIL import Image
    import io as _io
    if icon_bytes is not None:
        src = Image.open(_io.BytesIO(icon_bytes)).convert('RGBA')
    else:
        src = Image.open(ICON_PNG).convert('RGBA')
    out = {}
    sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    for dpi, size in sizes.items():
        pass
    for dpi, size in sizes.items():
        icon = src.resize((size, size), Image.LANCZOS)
        out['res/mipmap-%s/icon.webp' % dpi] = _webp(icon)
        fg_size = int(size * 1.5)
        fg = Image.new('RGBA', (fg_size, fg_size), (0, 0, 0, 0))
        inner = src.resize((int(size * 0.8), int(size * 0.8)), Image.LANCZOS)
        fg.paste(inner, ((fg_size - inner.width) // 2, (fg_size - inner.height) // 2), inner)
        out['res/mipmap-%s/icon_foreground.webp' % dpi] = _webp(fg)
        bg = Image.new('RGBA', (size, size), (26, 22, 20, 255))
        out['res/mipmap-%s/icon_background.webp' % dpi] = _webp(bg)
        mono = src.convert('L').resize((size, size), Image.LANCZOS).convert('RGBA')
        out['res/mipmap-%s/icon_monochrome.webp' % dpi] = _webp(mono)
    out['res/mipmap/icon.webp'] = _webp(src.resize((192, 192), Image.LANCZOS))
    return out


def density_of(path):
    # res/mipmap-xxxhdpi-v4/icon.webp -> xxxhdpi
    parts = path.split('/')
    if len(parts) < 2:
        return None
    d = parts[1]
    if not d.startswith('mipmap-'):
        return None
    d = d[len('mipmap-'):]
    for suffix in ('-v4', '-v2', '-anydpi-v26', '-anydpi'):
        if d.endswith(suffix):
            d = d[:-len(suffix)]
    return d


def _webp(img):
    buf = __import__('io').BytesIO()
    img.save(buf, 'WEBP', quality=95, method=6)
    return buf.getvalue()


# ---------------------------------------------------------------- apk

def patch_arsc(data):
    old = b'godot-project-name'
    new = LABEL.encode('utf-8')
    assert len(old) == len(new), (len(old), len(new))
    return data.replace(old, new)


def write_apk(out_path, entries, extra_files):
    """entries: list of (name, data, compress). extra_files: same but always deflated/stored."""
    zf = zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED)
    offsets = {}

    def add(name, data, compress):
        zi = zipfile.ZipInfo(name)
        zi.compress_type = zipfile.ZIP_STORED if compress == 0 else zipfile.ZIP_DEFLATED
        zi.external_attr = 0o644 << 16
        zi.date_time = (2026, 1, 1, 0, 0, 0)
        if compress == 0 and name.endswith('.so'):
            # page align the data of uncompressed native libraries
            info = zf.filelist
            cur = zf.fp.tell() if zf.fp else 0
            zf.writestr(zi, data, compress_type=zi.compress_type)
            # patch afterwards: alignment is applied below by rewriting the extra field
        else:
            zf.writestr(zi, data, compress_type=zi.compress_type)

    for name, data, compress in entries:
        add(name, data, compress)
    for name, data in extra_files:
        add(name, data, 0 if name.endswith(STORED_EXT) else 1)
    zf.close()


def align_and_fix(path):
    """Rewrite the zip so that uncompressed .so entries are 4096 byte aligned."""
    src = zipfile.ZipFile(path)
    items = [(i, src.read(i.filename)) for i in src.infolist()]
    src.close()
    out = zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED)
    for info, data in items:
        zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
        zi.compress_type = info.compress_type
        zi.external_attr = info.external_attr
        zi.create_system = 0
        if info.compress_type == zipfile.ZIP_STORED and info.filename.endswith('.so'):
            # compute padding so the file data starts on a 4096 boundary
            pos = out.fp.tell()
            header_len = 30 + len(info.filename.encode('utf-8'))
            need = (ALIGN - ((pos + header_len) % ALIGN)) % ALIGN
            extra = b''
            if need:
                # android alignment extra field (id 0xd935), data padded to 4 bytes
                payload_len = need - 4
                extra = struct.pack('<HH', 0xd935, payload_len) + b'\x00' * payload_len
            zi.extra = extra
        out.writestr(zi, data, compress_type=zi.compress_type)
    out.close()


def find_tool(name):
    """Locate an Android SDK build-tool, honouring ANDROID_HOME / ANDROID_SDK_ROOT."""
    override = os.environ.get('ABUELA_' + name.upper())
    if override:
        return override
    roots = [os.environ.get('ANDROID_HOME'), os.environ.get('ANDROID_SDK_ROOT'),
             '/opt/android-sdk', os.path.expanduser('~/Android/Sdk')]
    for root in roots:
        if not root:
            continue
        bt = os.path.join(root, 'build-tools')
        if not os.path.isdir(bt):
            continue
        for ver in sorted(os.listdir(bt), reverse=True):
            cand = os.path.join(bt, ver, name)
            if os.path.exists(cand):
                return cand
    which = shutil.which(name)
    if which:
        return which
    raise SystemExit('could not find %s; set ABUELA_%s' % (name, name.upper()))


def main():
    pck = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT_DIR, 'game_touch.pck')
    out_apk = sys.argv[2] if len(sys.argv) > 2 else os.path.join(OUT_DIR, 'ABUELA.apk')
    os.makedirs(WORK, exist_ok=True)
    files = read_pck(pck)
    print('pack: %s -> %d files' % (pck, len(files)))

    icon_bytes = dict(files).get('icon.png')
    icons = build_icons(icon_bytes)
    tpl = zipfile.ZipFile(TEMPLATE_APK)
    entries = []
    replaced = 0
    for info in tpl.infolist():
        data = tpl.read(info.filename)
        base = info.filename.rsplit('/', 1)[-1]
        dens = density_of(info.filename)
        if base in ICON_FILES and dens:
            key = 'res/mipmap-%s/%s' % (dens, base)
            if key in icons:
                data = icons[key]
                replaced += 1
            else:
                print('  ! no icon generated for', key)
        elif info.filename == 'resources.arsc':
            data = patch_arsc(data)
            replaced += 1
        entries.append((info.filename, data, 0 if info.compress_type == zipfile.ZIP_STORED else 1))
    tpl.close()
    print('template entries: %d (patched %d)' % (len(entries), replaced))

    extra = []
    for p, data in files:
        extra.append(('assets/' + p, data))
    extra.append(('assets/assets.sparsepck', sparse_metadata(files)))

    tmp = os.path.join(WORK, 'abuela_unaligned.apk')
    write_apk(tmp, entries, extra)
    align_and_fix(tmp)
    print('built %s: %d bytes' % (tmp, os.path.getsize(tmp)))

    if not os.path.exists(KEYSTORE):
        subprocess.run(['keytool', '-genkeypair', '-v', '-keystore', KEYSTORE, '-alias', 'abuela',
                        '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000',
                        '-storepass', KS_PASS, '-keypass', KS_PASS,
                        '-dname', 'CN=ABUELA Port, OU=Android Port, O=ABUELA, L=NA, S=NA, C=NA'], check=True)
    apksigner = find_tool('apksigner')
    if os.path.exists(out_apk):
        os.remove(out_apk)
    subprocess.run([apksigner, 'sign', '--ks', KEYSTORE, '--ks-pass', 'pass:' + KS_PASS,
                    '--key-pass', 'pass:' + KS_PASS, '--ks-key-alias', KS_ALIAS,
                    '--min-sdk-version', '21', '--out', out_apk, tmp], check=True)
    subprocess.run([apksigner, 'verify', '--verbose', out_apk], check=True)
    print('APK:', out_apk, os.path.getsize(out_apk), 'bytes')


if __name__ == '__main__':
    main()
