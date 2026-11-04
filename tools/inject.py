import sys, os, struct
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import pck, ecfg_patch

EXE = (os.environ.get('ABUELA_BASE') or os.environ.get('ABUELA_EXE')
       or os.path.join(ROOT, 'assets', 'game_base.pck'))
IS_PCK = EXE.lower().endswith('.pck')
PCK_OFF = 0 if IS_PCK else (int(os.environ.get('ABUELA_PCK_OFFSET', '0'), 0) or 0x6831200)

def _dir_end(f):
    f.seek(PCK_OFF)
    hdr = f.read(112)
    file_base, dir_off = struct.unpack('<2Q', hdr[24:40])
    f.seek(PCK_OFF + dir_off)
    cnt = struct.unpack('<I', f.read(4))[0]
    for _ in range(cnt):
        ln = struct.unpack('<I', f.read(4))[0]
        f.read(ln + 16 + 16 + 4)
    return f.tell()

def build(out_pck, autoloads=(), extra_files=None, project_patch=None, drop_files=()):
    p = pck.Pck.from_exe(EXE, PCK_OFF)
    with open(EXE, 'rb') as f:
        dir_end = _dir_end(f)
        f.seek(dir_end)
        p.trailer = f.read()          # footer of the original pack
    entries = ecfg_patch.parse(p.get_file('project.binary'))
    for name, path in autoloads:
        ecfg_patch.set_string(entries, 'autoload/' + name, '*' + path)
    if project_patch:
        for k, v in project_patch.items():
            ecfg_patch.set_string(entries, k, v)
    p.set_file('project.binary', ecfg_patch.build(entries))
    if extra_files:
        for path, content in extra_files.items():
            p.set_file(path, content if isinstance(content, bytes) else content.encode('utf-8'))
    for d in drop_files:
        p.files.pop(d, None)
        if d in p.order:
            p.order.remove(d)
    os.makedirs(os.path.dirname(out_pck), exist_ok=True)
    n = p.write(out_pck)
    print('wrote %s: %d bytes, %d files' % (out_pck, n, len(p.files)))
    return p

if __name__ == '__main__':
    probe = open(os.path.join(ROOT, 'probe', 'probe.gd'), 'rb').read()
    build(os.path.join(ROOT, 'out', 'game_probe.pck'),
          autoloads=[('Probe', 'res://probe/probe.gd')],
          extra_files={'probe/probe.gd': probe})
