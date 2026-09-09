#!/usr/bin/env python3
"""Host checks use real qemu-img; no guest or physical disk is required."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "vm_image", Path(__file__).resolve().parents[1] / "scripts/build-vm-image.py")
vm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vm)


class VMImageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self, extra=None):
        path = self.root / "release.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("bzimage", b"kernel")
            archive.writestr("bzroot", b"root")
            if extra:
                archive.writestr(extra, b"unsafe")
        return path

    def test_pinned_zip_and_hash_mismatch(self):
        path = self.archive()
        vm.verify_zip(path, vm.sha256(path))
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            vm.verify_zip(path, "0" * 64)

    def test_zip_rejects_traversal_symlinks_and_licenses(self):
        link = zipfile.ZipInfo("config/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        for name in ("../escape", "/absolute", "config/../escape", "config\\..\\escape",
                     "config/Pro.key", link):
            with self.subTest(name=name):
                path = self.archive(name)
                with self.assertRaises(ValueError):
                    vm.verify_zip(path, vm.sha256(path))

    def test_missing_boot_payload(self):
        path = self.root / "bad.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("bzimage", b"kernel")
        with self.assertRaisesRegex(ValueError, "missing"):
            vm.verify_zip(path, vm.sha256(path))

    def test_guest_script_syntax(self):
        subprocess.run(["bash", "-n"], input=vm.GUEST_MENU, text=True, check=True)

    @unittest.skipUnless(shutil.which("qemu-img"), "qemu-img is required")
    def test_compressed_image_round_trip_and_smallest_selection(self):
        raw = self.root / "boot.raw"
        with raw.open("wb") as file:
            file.write(bytes(range(256)) * 1024)
            file.seek(8 * 1024 * 1024)
            file.write(b"boot partition" * 10000)
            file.truncate(16 * 1024 * 1024)
        selected, method, sizes = vm.compress_image(raw, self.root, "smallest")
        self.assertEqual(selected.stat().st_size, min(sizes.values()))
        self.assertEqual(sizes[method], selected.stat().st_size)
        self.assertLess(selected.stat().st_size, raw.stat().st_size)
        restored = self.root / "restored.raw"
        vm.run("qemu-img", "convert", "-f", "qcow2", "-O", "raw", selected, restored)
        self.assertEqual(vm.sha256(raw), vm.sha256(restored))


    def test_boot_identity_tracks_actual_pool_and_preserves_other_settings(self):
        self.check_boot_identity("NEW_MODEL_custom-serial", "diskId=\"NEW_MODEL_custom-serial\"")

    def test_boot_identity_refuses_ambiguous_pool_or_missing_identity(self):
        for members, identity in [("/dev/nvme0n1p3\n/dev/sda3", "new-id"),
                                  ("/dev/nvme0n1p3", ""),
                                  ("/dev/nvme0n1p3", "bad id")]:
            with self.subTest(members=members, identity=identity):
                self.check_boot_identity(identity, None, members)

    def check_boot_identity(self, identity, expected, members="/dev/nvme0n1p3"):
        boot = self.root / "boot"
        helpers = boot / "config/vm-image"
        helpers.mkdir(parents=True, exist_ok=True)
        (helpers / "disk_identity.sh").write_text(
            'resolve_disk_id() { printf "%s\\n" "$TEST_IDENTITY"; }\n')
        pools = boot / "config/pools"
        pools.mkdir(exist_ok=True)
        cfg = pools / "boot.cfg"
        original = 'diskId="old-model_old-serial"\ndiskComment="preserve this"\n'
        cfg.write_text(original)
        commands = self.root / "commands"
        commands.mkdir(exist_ok=True)
        for name, body in {
            "findmnt": 'echo flash/boot',
            "zpool": 'printf "%s\\n" "$TEST_MEMBERS"',
            "readlink": 'echo /dev/nvme0n1p3',
            "lsblk": 'echo nvme0n1',
            "chmod": 'exit 0',
            "sync": 'exit 0',
        }.items():
            command = commands / name
            command.write_text('#!/bin/sh\n' + body + '\n')
            command.chmod(0o755)
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TEST_IDENTITY=identity, TEST_MEMBERS=members)
        result = subprocess.run(["bash", str(vm.REPO / "scripts/vm-boot-identity.sh"), str(boot)],
                                env=env, capture_output=True, text=True)
        if expected is None:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(cfg.read_text(), original)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(cfg.read_text(), expected + '\ndiskComment="preserve this"\n')
            before = cfg.stat().st_mtime_ns
            subprocess.run(["bash", str(vm.REPO / "scripts/vm-boot-identity.sh"), str(boot)],
                           env=env, capture_output=True, check=True)
            self.assertEqual(cfg.stat().st_mtime_ns, before)

    def build_args(self):
        iso = self.root / "installer.iso"
        iso.write_bytes(b"iso")
        archive = self.archive()
        lock = self.root / "release.json"
        lock.write_text(json.dumps({"channel": "stable", "version": "7.3.2",
                                   "url": "https://releases.unraid.net/dl/stable/7.3.2/file.zip",
                                   "sha256": vm.sha256(archive)}))
        return argparse.Namespace(iso=iso, unraid_zip=archive, release_lock=lock,
                                  output=self.root / "unraid-vm.qcow2", force=False,
                                  accel="tcg", disk_mib=8192, ram_mib=8192,
                                  timeout=1, compression="smallest")

    def test_refuses_existing_image_before_running_commands(self):
        args = self.build_args()
        args.output.write_bytes(b"old image")
        with patch.object(vm, "run") as run:
            with self.assertRaisesRegex(ValueError, "Output exists"):
                vm.build(args)
            run.assert_not_called()
        self.assertEqual(args.output.read_bytes(), b"old image")

    def test_failed_build_preserves_previous_artifacts_and_removes_staging(self):
        args = self.build_args()
        args.force = True
        args.output.write_bytes(b"old image")
        manifest = Path(str(args.output) + ".json")
        manifest.write_text("old manifest")
        with patch.object(vm.shutil, "which", return_value="tool"):
            with patch.object(vm, "run", side_effect=subprocess.CalledProcessError(1, "xorriso")):
                with self.assertRaises(subprocess.CalledProcessError):
                    vm.build(args)
        self.assertEqual(args.output.read_bytes(), b"old image")
        self.assertEqual(manifest.read_text(), "old manifest")
        self.assertEqual(list(self.root.glob(".vm-image-*")), [])

    def test_timed_out_guest_is_stopped_without_publishing(self):
        args = self.build_args()
        guest = MagicMock()
        guest.wait.side_effect = [subprocess.TimeoutExpired("qemu", 1), 0]
        guest.poll.return_value = None
        process = MagicMock()
        process.__enter__.return_value = guest
        with patch.object(vm.shutil, "which", return_value="tool"), \
                patch.object(vm, "run"), \
                patch.object(vm.subprocess, "Popen", return_value=process), \
                patch.object(vm, "compress_image") as compress:
            with self.assertRaises(subprocess.TimeoutExpired):
                vm.build(args)
        guest.terminate.assert_called_once()
        compress.assert_not_called()
        self.assertFalse(args.output.exists())
        self.assertFalse(Path(str(args.output) + ".json").exists())
        self.assertEqual(list(self.root.glob(".vm-image-*")), [])


if __name__ == "__main__":
    unittest.main()
