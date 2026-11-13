"""Exercise backup validation without importing pools or writing target disks."""
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXISTING = (ROOT / 'scripts/menu_recovery_restore_existing.sh').read_text()
CREATE = (ROOT / 'scripts/create_internal_boot_user.sh').read_text()


def function(source, name):
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)[0]


def validate(path, route, env=None):
    if route == 'existing':
        code = function(EXISTING, 'archive_contains_symlink') + '\n' + function(EXISTING, 'validate_backup')
        code += '\nbackup_file="$1"\nvalidate_backup\n'
    else:
        start = CREATE.index('    ZIP_FILE="$RESTORE_BACKUP"')
        end = CREATE.index('\nelif compgen ', start)
        code = function(CREATE, 'archive_contains_symlink')
        code += '\nerror_msg() { echo "$*" >&2; }\nstatus_msg() { :; }\nRESTORE_BACKUP="$1"\n'
        code += CREATE[start:end] + '\n'
    return subprocess.run(['/bin/bash', '-c', 'set -euo pipefail\n' + code, 'validate', str(path)],
                          env=env, capture_output=True, text=True)


class RestoreValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def archive(self, name='backup.zip', missing=None, extra=None):
        path = self.root / name
        with zipfile.ZipFile(path, 'w') as archive:
            for entry in ('config/', 'bzimage', 'grub/grub.cfg'):
                if entry != missing:
                    archive.writestr(entry, b'' if entry.endswith('/') else b'payload')
            if extra is not None:
                archive.writestr(extra, b'unsafe')
            for i in range(4000):
                archive.writestr(f'plugins/long-directory-name-{i:05d}/settings.txt', b'x')
        return path

    def check_routes(self, path, expected, env=None):
        for route in ('existing', 'create'):
            with self.subTest(route=route, archive=path.name):
                result = validate(path, route, env)
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def test_large_valid_archive(self):
        path = self.archive()
        self.check_routes(path, True)
        # A bounded pipe makes the quiet-grep failure deterministic.
        script = '''import os, subprocess, sys
r,w=os.pipe()
import fcntl
fcntl.fcntl(w, fcntl.F_SETPIPE_SZ, 4096)
p=subprocess.Popen(['unzip','-Z1',sys.argv[1]],stdout=w)
os.close(w)
g=subprocess.run(['grep','-qx','config/'],stdin=r)
os.close(r)
print(p.wait(),g.returncode)
'''
        if os.path.exists('/proc/sys/fs/pipe-max-size'):
            import sys
            result = subprocess.run([sys.executable, '-c', script, str(path)], capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), '-13 0', result.stderr)

    def test_missing_required_entries(self):
        for entry in ('config/', 'bzimage'):
            self.check_routes(self.archive(missing=entry), False)

    def test_unsafe_paths_early_in_large_listing(self):
        for entry in ('../outside', '/absolute', 'config/../../outside'):
            self.check_routes(self.archive(extra=entry), False)

    def test_symlink(self):
        path = self.archive()
        with zipfile.ZipFile(path, 'a') as archive:
            item = zipfile.ZipInfo('config/link')
            item.create_system = 3
            item.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(item, '../outside')
        self.check_routes(path, False)

    def test_invalid_zip(self):
        path = self.root / 'invalid.zip'
        path.write_bytes(b'not a zip')
        self.check_routes(path, False)

    def test_damaged_payload(self):
        path = self.archive()
        with zipfile.ZipFile(path) as archive:
            entry = archive.getinfo('bzimage')
            offset = entry.header_offset + 30 + len(entry.filename.encode()) + len(entry.extra)
        with path.open('r+b') as stream:
            stream.seek(offset)
            stream.write(b'BROKEN!')
        self.check_routes(path, False)

    def test_listing_error_after_required_names(self):
        path = self.archive()
        stub = self.root / 'unzip'
        real = subprocess.check_output(['which', 'unzip'], text=True).strip()
        stub.write_text('#!/bin/bash\nif [[ "$1" == "-Z1" ]]; then\n'
                        ' printf "config/\\nbzimage\\n"; exit 2\nfi\n'
                        f'exec "{real}" "$@"\n')
        stub.chmod(0o755)
        self.check_routes(path, False, {**os.environ, 'PATH': str(self.root) + ':' + os.environ['PATH']})


if __name__ == '__main__':
    unittest.main()
