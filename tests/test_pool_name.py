"""Check the internal-boot pool-name field without running the installer."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "scripts/create_internal_boot_user.sh").read_text()
BASH = shutil.which("bash")


def function(name):
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)[0]


class PoolNameTests(unittest.TestCase):
    def test_name_rules(self):
        valid = ("boot", "a", "cache_ssd", "fast-pool", "cache2ssd", "cache~sub",
                 "cache.ssd", "cache_", "cache-", "a" * 40, "logdata", "diskdata")
        invalid = ("", "Boot", "cache1", "1cache", "_cache", "cache.", "cache~",
                   "pool name", "pool\tname", "pool\nname", "caché", "../pool",
                   "cache/pool", "a" * 41, "flash", "user", "dev", "remotes",
                   "recyclebin", "rootshare", "disks", "addons", "homes", "global",
                   "printers", "log", "disk", "parity", "diskp", "diskq", "diskr",
                   "mirror", "mirror_ssd", "raidz2_ssd", "draid_ssd", "spare_disks")
        code = function("is_valid_pool_name") + '\nis_valid_pool_name "$1"\n'
        for name in valid + invalid:
            with self.subTest(name=name):
                result = subprocess.run([BASH, "-c", code, "validator", name],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, name in valid)
                if name in invalid:
                    self.assertTrue(result.stdout.strip())

    def test_prompt_retry_and_default(self):
        code = function("is_valid_pool_name") + "\n" + function("prompt_boot_pool_name") + r'''
ui_prompt() { local value; IFS= read -r value; printf '%s\n' "$value"; }
ui_msg() { printf '%s: %s\n' "$1" "$2"; }
prompt_boot_pool_name
printf 'SELECTED=%s\n' "$BOOT_POOL_NAME"
'''
        for backend in ("text", "dialog", "whiptail"):
            for names, selected, errors in (("bad name\nmirror\ncache1\n cache_ssd \n", "cache_ssd", 3),
                                             ("\n", "boot", 0)):
                with self.subTest(backend=backend, names=names):
                    env = {**os.environ, "BOOT_POOL_NAME": "boot", "ui_backend": backend}
                    result = subprocess.run([BASH, "-c", code], input=names, env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.lower().count("invalid pool name"), errors)
                    self.assertIn("SELECTED=" + selected, result.stdout)


if __name__ == "__main__":
    unittest.main()
