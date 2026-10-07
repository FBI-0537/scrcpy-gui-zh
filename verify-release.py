#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""发布前验收：检查打包产物「该有的都在、架构也对」。

用法：
    python3 verify-release.py release/1.0.0                 # 递归检查整个目录
    python3 verify-release.py dist/*                        # 检查若干文件
    python3 verify-release.py dist/scrcpy-gui-zh-1.0.0-...  # 检查单个文件

检查项：
    1. 可执行文件类型（ELF / PE）与架构（x86-64 / aarch64 / armv7 / i386 / arm64-windows）
    2. 架构是否与**文件名**一致 —— 防止把 arm64 产物命名成 x86_64 发出去
    3. 是不是 PyInstaller 单文件包（文件尾部有 MEI cookie）
    4. 包内清单里是否含关键组件：
         scrcpy、adb、scrcpy-server、install-udev.sh
         + 依赖库 .so + tkinter（+ segno 的痕迹）
    5. 体积是否落在合理区间（明显偏小通常意味着没打全）
"""
import os
import re
import struct
import sys

# Windows 运行器的控制台默认是 cp1252，直接 print 中文会 UnicodeEncodeError
# （实测 CI 里验收脚本就是这样崩的）。强制切成 UTF-8 输出。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass



COOKIE_MAGIC = b'MEI\014\013\012\013\016'

ELF_MACHINES = {
    0x03: ('i386', 32),
    0x28: ('armv7l', 32),
    0x3E: ('x86_64', 64),
    0xB7: ('aarch64', 64),
    0x08: ('mips', 32),
    0x15: ('ppc', 32),
    0x16: ('s390', 32),
    0x14: ('ppc64', 64),
    0x102: ('ppc64le', 64),
    0xF3: ('riscv32', 32),
    0xF7: ('riscv64', 64),
}

PE_MACHINES = {
    0x014C: ('i386', 32),
    0x8664: ('x86_64', 64),
    0xAA64: ('arm64', 64),
    0x01C4: ('armv7l', 32),
}

# 文件名里可能出现的架构标记 → 期望的实际架构
NAME_ARCH_HINTS = (
    ('x86_64', 'x86_64'), ('amd64', 'x86_64'), ('x64', 'x86_64'),
    ('aarch64', 'aarch64'), ('arm64', 'aarch64'),
    ('armv7l', 'armv7l'), ('armhf', 'armv7l'), ('armv7', 'armv7l'),
    ('i386', 'i386'), ('i686', 'i386'),
)

# 关键组件：按平台区分（Windows 不需要 install-udev.sh，依赖是 .dll 不是 .so）
KEY_COMPONENTS = {
    'ELF': (
        ('scrcpy 可执行文件', (b'scrcpy',)),
        ('adb', (b'platform-tools', b'adb')),
        ('scrcpy-server', (b'scrcpy-server',)),
        ('install-udev.sh', (b'install-udev.sh',)),
        ('Tcl/Tk（图形界面）', (b'_tkinter', b'tkinter', b'tcl8')),
        ('segno（二维码）', (b'segno',)),
    ),
    'PE': (
        ('scrcpy.exe', (b'scrcpy.exe',)),
        ('adb.exe 及其 USB 驱动 DLL', (b'adb.exe', b'AdbWinApi')),
        ('scrcpy-server', (b'scrcpy-server',)),
        ('Tcl/Tk（图形界面）', (b'tk86t.dll', b'tcl86t.dll', b'_tkinter')),
        ('segno（二维码）', (b'segno',)),
    ),
}

# 依赖库特征：至少要凑够若干个，说明依赖收集真的生效了
LIB_HINTS = {
    'ELF': (b'libavcodec.so', b'libavformat.so', b'libavutil.so',
            b'libswresample.so', b'libSDL2', b'libSDL3', b'libusb-1.0.so', b'libX11.so'),
    'PE': (b'avcodec-', b'avformat-', b'avutil-', b'swresample-',
           b'SDL3.dll', b'SDL2.dll', b'libusb-1.0.dll', b'zlib1.dll'),
}

# 从包里清点库文件名（PyInstaller 的 TOC 名字是明文的）
LIB_NAME_RE = {
    'ELF': re.compile(rb'[A-Za-z0-9_.+\-]{2,44}\.so(?:\.[0-9.]+)*'),
    'PE': re.compile(rb'[A-Za-z0-9_.+\-]{2,44}\.(?:dll|exe)'),
}
# TOC 里文件名前面会紧贴一个类型字节（b/x/z/m/s/d...），需要剥掉
_CANON_START = re.compile(
    r'^(lib|SDL|av|sw|tcl|tk|zlib|python|VCRUNTIME|AdbWin|scrcpy|adb|ffmpeg|usb)')


def _canon_lib(name):
    if _CANON_START.match(name):
        return name
    if len(name) > 2 and _CANON_START.match(name[1:]):
        return name[1:]
    return name


def list_bundled_libs(data, fmt):
    pattern = LIB_NAME_RE.get(fmt)
    if pattern is None:
        return []
    names = set()
    for match in pattern.finditer(data):
        raw = match.group(0).decode('latin-1')
        names.add(_canon_lib(raw))
    return sorted(names)


def read_header(path):
    """返回 (格式, 架构, 位数) 或 (None, None, None)。"""
    with open(path, 'rb') as fh:
        head = fh.read(64)
    if head[:4] == b'\x7fELF':
        if len(head) < 20:
            return None, None, None
        bits = 32 if head[4] == 1 else 64
        endian = '<' if head[5] == 1 else '>'
        machine = struct.unpack(endian + 'H', head[18:20])[0]
        name = ELF_MACHINES.get(machine, ('unknown-0x%x' % machine, bits))[0]
        return 'ELF', name, bits
    if head[:2] == b'MZ' and len(head) >= 64:
        pe_off = struct.unpack('<I', head[0x3C:0x40])[0]
        with open(path, 'rb') as fh:
            fh.seek(pe_off)
            sig = fh.read(6)
        if sig[:4] == b'PE\0\0':
            machine = struct.unpack('<H', sig[4:6])[0]
            name, bits = PE_MACHINES.get(machine, ('unknown-0x%x' % machine, 0))
            return 'PE', name, bits
    return None, None, None


def expected_arch(filename):
    """从文件名**或所在路径**里推断期望架构（有人把架构写在目录名上）。"""
    low = filename.lower().replace('\\', '/')
    for hint, arch in NAME_ARCH_HINTS:
        if hint in low:
            return arch
    return None


def scan_components(path, fmt):
    """把文件读进来做特征串扫描（PyInstaller 的 TOC 名字是明文的）。"""
    with open(path, 'rb') as fh:
        data = fh.read()
    found = {}
    for label, needles in KEY_COMPONENTS.get(fmt, KEY_COMPONENTS['ELF']):
        found[label] = any(n in data for n in needles)
    libs = sum(1 for h in LIB_HINTS.get(fmt, LIB_HINTS['ELF']) if h in data)
    has_cookie = COOKIE_MAGIC in data
    return found, libs, has_cookie, data


def check_bundle(bundle_dir, exe_path, fmt, want_arch, ok):
    """目录版（--onedir）的验收：组件是真实文件，按文件名核对。

    目录版没有 MEI cookie（那是单文件包专属），所以不能沿用 check() 的
    字节扫描，改为看目录里到底有没有这些文件。
    """
    names = []
    n_dirs = 0
    for root, dirs, fs in os.walk(bundle_dir):
        names.extend(fs)
        n_dirs += len(dirs)
    lower = [n.lower() for n in names]

    # 替代 cookie 的标记
    has_internal = os.path.isdir(os.path.join(bundle_dir, '_internal'))
    has_pyz = any(n.startswith('pyz-00.pyz') for n in lower)
    has_base = any(n == 'base_library.zip' for n in lower)
    if has_internal or has_pyz or has_base:
        print('  [OK]   目录版结构完整（_internal=%s, PYZ=%s, base_library=%s）'
              % ('有' if has_internal else '无',
                 '有' if has_pyz else '无',
                 '有' if has_base else '无'))
    else:
        print('  [失败] 既没有 _internal 也没有 PYZ —— 不像 PyInstaller 目录版')
        ok = False

    want_files = (
        ('scrcpy', ('scrcpy',)),
        ('adb', ('adb',)),
        ('scrcpy-server', ('scrcpy-server', 'scrcpy_server')),
        ('udev 安装脚本', ('install-udev.sh',)),
    )
    for label, needles in want_files:
        if any(n == x or n.startswith(x) for n in lower for x in needles):
            print('  [OK]   目录内含 %s' % label)
        else:
            print('  [失败] 目录里找不到 %s' % label)
            ok = False

    libs = [n for n in names if '.so' in n.lower() or n.lower().endswith('.dll')]
    if len(libs) >= 3:
        print('  [OK]   依赖库 %d 个（依赖收集生效）' % len(libs))
    elif libs:
        print('  [注意] 依赖库只有 %d 个，可能没收集全' % len(libs))
    else:
        print('  [失败] 一个依赖库都没有 —— 依赖可能没打进去')
        ok = False

    if libs:
        print('  目录内库/可执行文件清单（%d 个，最多列 24 个）：' % len(libs))
        for n in sorted(libs)[:24]:
            print('        %s' % n)

    print('  可执行文件：%s' % os.path.basename(exe_path))
    print('  结论：%s' % ('通过' if ok else '不通过'))
    return ok


def check(path):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    print('=' * 72)
    print('文件：%s' % name)
    print('大小：%.1f MB（%d 字节）' % (size / 1024.0 / 1024.0, size))

    if size < 1024 * 1024:
        print('  [警告] 小于 1MB，不像是「依赖全打包」的单文件产物')

    fmt, arch, bits = read_header(path)
    if fmt is None:
        print('  [失败] 不是可执行文件（ELF/PE 都不是）')
        return False
    print('  格式：%s   架构：%s（%s 位）' % (fmt, arch, bits or '?'))

    ok = True
    want = expected_arch(path)
    if want is None:
        print('  [注意] 路径与文件名里都没有架构标记，无法比对（建议命名带上架构）')
    elif want != arch:
        print('  [失败] 文件名声明 %s，实际是 %s —— 发出去会装不上！' % (want, arch))
        ok = False
    else:
        print('  [OK]   架构与文件名一致（%s）' % arch)

    # 目录版（--onedir）：可执行文件与依赖同目录，没有 MEI cookie，
    # 按真实文件名核对（这里是 <名称>/<名称> 布局）
    bundle_dir = os.path.dirname(path)
    if os.path.basename(bundle_dir) == name and os.path.isdir(bundle_dir):
        print('  形态：目录版（--onedir，解压即用）')
        return check_bundle(bundle_dir, path, fmt, want, ok)

    found, libs, has_cookie, data = scan_components(path, fmt)
    if has_cookie:
        print('  [OK]   是 PyInstaller 单文件包（找到 MEI cookie）')
    else:
        print('  [失败] 没有 MEI cookie —— 不是单文件包，或者被打包工具改过')
        ok = False

    for label, present in found.items():
        if present:
            print('  [OK]   包内含 %s' % label)
        else:
            print('  [失败] 包里找不到 %s' % label)
            ok = False

    hint_total = len(LIB_HINTS.get(fmt, ()))
    if libs >= max(3, hint_total // 2):
        print('  [OK]   依赖库特征命中 %d/%d 项（依赖收集生效）' % (libs, hint_total))
    elif libs > 0:
        print('  [注意] 依赖库特征只命中 %d/%d 项，可能没收集全' % (libs, hint_total))
    else:
        print('  [失败] 一个依赖库特征都没命中 —— 依赖可能没打进去')
        ok = False

    bundled = list_bundled_libs(data, fmt)
    if bundled:
        print('  包内库/可执行文件清单（%d 个，最多列 24 个）：' % len(bundled))
        for name in bundled[:24]:
            print('        %s' % name)
        if len(bundled) > 24:
            print('        …（还有 %d 个）' % (len(bundled) - 24))

    print('  ==> %s' % ('通过' if ok else '不通过'))
    return ok


# 附带文件不是产物：功能说明 .txt、校验和 SHA256SUMS/.sha256、签名等。
# 它们跟可执行文件一起发布，但不是 ELF/PE，不能按产物去校验 ——
# 否则「每个文件都必须是可执行文件」这条会把它们判失败。
COMPANION_EXT = ('.txt', '.md', '.json', '.sha256', '.sha256sum',
                 '.sig', '.asc', '.sums', '.log', '.gz', '.xz', '.zip',
                 '.tar')
# 目录版（--onedir）打成 .tar.gz 发布，里面是可执行文件目录；
# 它由构建时的容器内自检（--selftest）保证，这里不按 ELF 校验。


def is_companion(name):
    low = name.lower()
    if name.startswith('.'):
        return True
    if low.startswith('sha256sums') or low.startswith('md5sums'):
        return True
    return low.endswith(COMPANION_EXT)


def collect(targets):
    files = []
    companions = []
    for t in targets:
        if os.path.isdir(t):
            for root, dirs, names in os.walk(t):
                # 目录版（--onedir）的解压结果：<名称>/<名称> 是可执行文件，
                # 同目录下还有依赖库、内嵌的 scrcpy/adb 等。
                #   → 只把「与目录同名的那个可执行文件」当产物校验，
                #     不进目录里逐个校验（否则几百个文件全部误判失败；
                #     实测连续两轮把 6 个目标搞成全红）。
                # 目录内容的正确性由构建时的容器内 --selftest 保证。
                for d in list(dirs):
                    if d.endswith('-dir'):
                        dirs.remove(d)
                        continue
                    main = os.path.join(root, d, d)
                    if os.path.isfile(main):
                        files.append(main)
                        dirs.remove(d)
                for n in names:
                    full = os.path.join(root, n)
                    (companions if is_companion(n) else files).append(full)
        elif os.path.isfile(t):
            (companions if is_companion(os.path.basename(t)) else files).append(t)
        else:
            print('跳过（不存在）：%s' % t)
    files.sort()
    companions.sort()
    return files, companions


def self_test():
    """用合成目录校验"哪些算产物、哪些算附带"的分类逻辑。

    防的是这类事故：改了 dist/ 的产出布局（例如新增 --onedir 目录版），
    却忘了同步验收脚本 → 发布验收全红，而且只有跑一轮 CI 才发现。
    用法：python3 verify-release.py --self-test
    """
    import shutil

    base = os.path.join(os.getcwd(), "_vr_selftest")
    shutil.rmtree(base, ignore_errors=True)
    dist = os.path.join(base, "dist")
    os.makedirs(os.path.join(dist, "demo-dir", "lib"), exist_ok=True)

    # 目录版里的运行时文件（不该被当成产物）
    for rel in (("demo-dir", "demo"), ("demo-dir", "lib", "libx.so.1")):
        with open(os.path.join(dist, *rel), "wb") as fh:
            fh.write(b"\x7fELF" + b"\x00" * 60)
    # 附带文件
    with open(os.path.join(dist, "demo.txt"), "w", encoding="utf-8") as fh:
        fh.write("说明")
    with open(os.path.join(dist, "demo-dir.tar.gz"), "wb") as fh:
        fh.write(b"\x1f\x8b" + b"\x00" * 20)
    with open(os.path.join(dist, "SHA256SUMS.txt"), "w", encoding="utf-8") as fh:
        fh.write("deadbeef  demo\n")

    files, companions = collect([dist])
    problems = []
    leaked = [f for f in files if "-dir" + os.sep in f]
    if leaked:
        problems.append("目录版里的文件被当成产物：%s" % leaked)
    # 新布局：<名称>/<名称> 是产物，其余不该进名单
    os.makedirs(os.path.join(dist, "app-x"), exist_ok=True)
    with open(os.path.join(dist, "app-x", "app-x"), "wb") as fh:
        fh.write(b"\x7fELF" + b"\x00" * 60)
    with open(os.path.join(dist, "app-x", "liby.so.1"), "wb") as fh:
        fh.write(b"\x7fELF" + b"\x00" * 60)
    files2, _c2 = collect([dist])
    names2 = [os.path.basename(x) for x in files2]
    if "app-x" not in names2:
        problems.append("目录版主可执行文件没被识别为产物：%s" % names2)
    if "liby.so.1" in names2:
        problems.append("目录版里的依赖库被当成产物：%s" % names2)
    if os.path.join(dist, "demo.txt") not in companions:
        problems.append("demo.txt 应算附带文件")
    if os.path.join(dist, "demo-dir.tar.gz") not in companions:
        problems.append("demo-dir.tar.gz 应算附带文件")
    if os.path.join(dist, "SHA256SUMS.txt") not in companions:
        problems.append("SHA256SUMS.txt 应算附带文件")

    shutil.rmtree(base, ignore_errors=True)

    if problems:
        print("自检失败：")
        for p in problems:
            print("  · %s" % p)
        return 1
    print("自检通过：产物 %d 个、附带 %d 个，分类正确"
          % (len(files), len(companions)))
    return 0


def main(argv):

    if "--self-test" in argv:
        return self_test()
    if not argv:
        print(__doc__)
        return 2
    files, companions = collect(argv)
    if companions:
        print('附带文件（不按产物校验，跳过 %d 个）：' % len(companions))
        for c in companions:
            print('    %s' % os.path.basename(c))
        print()
    if not files:
        print('没有找到要检查的产物（只有附带文件）')
        return 2
    results = [check(f) for f in files]
    print('=' * 72)
    print('汇总：%d 个产物，%d 个通过，%d 个不通过（另有 %d 个附带文件已跳过）'
          % (len(results), sum(1 for r in results if r),
             sum(1 for r in results if not r), len(companions)))
    return 0 if all(results) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
