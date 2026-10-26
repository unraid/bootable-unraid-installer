"""Exercise the dependency gate without accessing a target disk."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/create_internal_boot_user.sh"
if not SCRIPT.exists():
    SCRIPT = ROOT / "persistent/runtime/partner/create_internal_boot.sh"
SOURCE = SCRIPT.read_text()


def function(name):
    return re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE, re.M | re.S)[0]


class MirrorRuntimeTests(unittest.TestCase):
    def gate(self, count, tool):
        with tempfile.TemporaryDirectory() as directory:
            if tool is not None:
                path = Path(directory) / "mcopy"
                path.write_text("#!/bin/bash\n" + tool + "\n")
                path.chmod(0o755)
            # Execute the actual preflight and subsequent destructive section.
            # Mock every operation so a regression cannot touch a disk.
            start = SOURCE.index("# Reject incompatible installer media")
            end = SOURCE.index('# -------------------------------\n# Recreate partitions', start)
            code = function("ensure_mirrored_efi_runtime") + '''
error_msg() { printf '%s\\n' "$*"; }
resolve_selected_disk_ids() { :; }
confirm() { echo CONFIRMED; return 0; }
step_update() { :; }
run_operation() { printf 'OPERATION %s\\n' "$*"; }
ui_backend=dialog
TARGET=/dev/fixture-a
TARGET_2=/dev/fixture-b
''' + f"\nBOOT_DEVICE_COUNT={count}\n" + SOURCE[start:end]
            env = {**os.environ, "PATH": directory}
            return subprocess.run(["/bin/bash", "-c", code], env=env,
                                  capture_output=True, text=True)

    def test_missing_tool_stops_before_confirmation_and_writes(self):
        result = self.gate(2, None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("latest installer ISO", result.stdout)
        self.assertNotIn("CONFIRMED", result.stdout)
        self.assertNotIn("OPERATION", result.stdout)

    def test_broken_tool_stops_before_confirmation_and_writes(self):
        result = self.gate(2, "exit 127")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("OPERATION", result.stdout)
        self.assertNotIn("CONFIRMED", result.stdout)

    def test_working_tool_allows_both_disks(self):
        result = self.gate(2, '[[ "$1" == "-V" ]]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CONFIRMED", result.stdout)
        self.assertIn("OPERATION wipefs -a /dev/fixture-a", result.stdout)
        self.assertIn("OPERATION wipefs -a /dev/fixture-b", result.stdout)

    def test_single_disk_does_not_require_mcopy(self):
        result = self.gate(1, None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OPERATION wipefs -a /dev/fixture-a", result.stdout)
        self.assertNotIn("OPERATION wipefs -a /dev/fixture-b", result.stdout)


class ImageRuntimeTests(unittest.TestCase):
    @unittest.skipUnless((ROOT / "scripts/build-iso.sh").exists(), "image builder is in the public repository")
    def test_image_packaging_requires_runnable_target_mcopy(self):
        source = (ROOT / "scripts/build-iso.sh").read_text()
        start = source.index("# Check the target runtime")
        end = source.index('echo "Packing initrd', start)
        gate = source[start:end]
        for status in (0, 127):
            with self.subTest(status=status):
                code = f"sudo() {{ return {status}; }}\nROOTFS=/fixture\n" + gate + "\necho PACKED\n"
                result = subprocess.run(["/bin/bash", "-c", code], capture_output=True, text=True)
                self.assertEqual("PACKED" in result.stdout, status == 0)
                if status:
                    self.assertIn("rebuild in full mode", result.stderr)
                    self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
