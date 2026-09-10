#!/usr/bin/env python3
"""Install the pinned Unraid release into a private disk and package it for QEMU."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.parse
import zipfile


REPO = Path(__file__).resolve().parent.parent
SERIAL = "UNRAID_VM_BOOT"

# The seed is private to this build. No host disks or network are exposed.
GUEST_MENU = r'''#!/bin/bash
set -euo pipefail
exec >/dev/ttyS0 2>&1
finish() {
    result=$?
    trap - EXIT
    set +e
    sync
    if (( result == 0 )); then
        echo UNRAID_VM_BUILD_RESULT=success
    else
        echo "UNRAID_VM_BUILD_RESULT=failure exit=$result"
    fi
    echo o > /proc/sysrq-trigger
    while true; do sleep 1; done
}
trap finish EXIT
[[ -b /dev/nvme0n1 ]]
printf '\nYES\nn\n' | BOOT_POOL_NAME=boot MENU_BACKEND=text \
    /bin/bash /boot/install/create_internal_boot.sh \
    --ui text --size 0 --disk-id QEMU_NVMe_Ctrl_UNRAID_VM_BOOT /dev/nvme0n1

# Reopen the exported pool to verify what the next boot will read.
mkdir -p /tmp/vm-verify
zpool import -N -o cachefile=none -R /tmp/vm-verify -d /dev/nvme0n1p3 flash
zfs mount flash/boot
boot_mount="$(zfs get -H -o value mountpoint flash/boot)"
[[ "$boot_mount" == /tmp/vm-verify/* ]]
test -s "$boot_mount/bzimage"
test -s "$boot_mount/bzroot"
test -s "$boot_mount/grub/grub.cfg"
grep -q 'unraiduuid=' "$boot_mount/grub/grub.cfg"
grep -qx 'diskId="QEMU_NVMe_Ctrl_UNRAID_VM_BOOT"' "$boot_mount/config/pools/boot.cfg"
test -z "$(find "$boot_mount/config" -iname '*.key' -print -quit)"
mcopy -i /dev/nvme0n1p2 ::/EFI/BOOT/BOOTX64.EFI /tmp/vm-bootx64.efi
test -s /tmp/vm-bootx64.efi
# Install the pre-management hook for normal and safe-mode startup.
mkdir -p "$boot_mount/config/vm-image"
cp "$PERSISTENT_ROOT/runtime/vm-boot-identity.sh" "$boot_mount/config/vm-image/"
cp "$PERSISTENT_ROOT/runtime/disk_identity.sh" "$boot_mount/config/vm-image/"
for startup in go go.safemode; do
    cat > "$boot_mount/config/$startup" <<'STARTUP'
#!/bin/bash
if ! /bin/bash /boot/config/vm-image/vm-boot-identity.sh; then
    echo 'VM boot identity failed; management startup stopped. Check the boot disk identity.' >&2
    exit 1
fi
/usr/local/sbin/emhttp
STARTUP
done
sed -i 's/^diskId=.*/diskId=""/' "$boot_mount/config/pools/boot.cfg"
zpool export flash
'''


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_lock(path):
    lock = json.loads(path.read_text())
    url = urllib.parse.urlsplit(lock["url"])
    if (url.scheme != "https" or url.netloc != "releases.unraid.net"
            or not url.path.startswith("/dl/stable/") or lock.get("channel") != "stable"):
        raise ValueError("Release lock must name an official stable HTTPS release")
    if not re.fullmatch(r"[0-9a-f]{64}", lock["sha256"]):
        raise ValueError("Invalid release SHA-256")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", lock["version"]):
        raise ValueError("Invalid release version")
    return lock


def verify_zip(path, expected_sha256):
    if sha256(path) != expected_sha256:
        raise ValueError("Unraid ZIP does not match the release-lock SHA-256")
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        if not {"bzimage", "bzroot"} <= names:
            raise ValueError("Unraid ZIP is missing bzimage or bzroot")
        for entry in archive.infolist():
            name = entry.filename.replace("\\", "/")
            if (name.startswith("/") or ".." in name.split("/")
                    or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                raise ValueError("Unraid ZIP contains an unsafe path or symbolic link")
            if name.lower().endswith(".key"):
                raise ValueError("Public VM images must not contain license keys")


def compress_image(raw, directory, compression):
    """Measure complete files, not allocated blocks; select the smallest download."""
    methods = ["zlib", "zstd"] if compression == "smallest" else [compression]
    candidates = []
    for method in methods:
        target = directory / (method + ".qcow2")
        run("qemu-img", "convert", "-f", "raw", "-O", "qcow2", "-c",
            "-o", "compat=1.1,compression_type=" + method, raw, target)
        candidates.append((target.stat().st_size, method, target))
    _, method, selected = min(candidates)
    run("qemu-img", "check", "-f", "qcow2", selected)
    run("qemu-img", "compare", "-f", "raw", "-F", "qcow2", raw, selected)
    info = json.loads(run("qemu-img", "info", "--output=json", "-f", "qcow2",
                          selected, capture_output=True, text=True).stdout)
    if info.get("backing-filename") or info["virtual-size"] != raw.stat().st_size:
        raise ValueError("QCOW2 is not a standalone copy of the installed disk")
    return selected, method, {method: size for size, method, _ in candidates}


def build(args):
    lock = release_lock(args.release_lock)
    output = args.output.resolve()
    if output.suffix != ".qcow2":
        raise ValueError("--output must end in .qcow2")
    outputs = [output, Path(str(output) + ".json"), Path(str(output) + ".sha256")]
    log_path = Path(str(output) + ".build.log")
    if any(path.is_symlink() or (path.exists() and not path.is_file()) for path in [*outputs, log_path]):
        raise ValueError("Output paths must be regular files, not devices, directories, or symlinks")
    if not args.force and any(path.exists() for path in outputs):
        raise ValueError("Output exists; use --force to replace it")
    if not args.iso.is_file():
        raise ValueError("Installer ISO does not exist")
    if args.accel == "kvm" and not os.access("/dev/kvm", os.R_OK | os.W_OK):
        raise ValueError("KVM is unavailable; use --accel tcg for software emulation")
    for command in ("qemu-system-x86_64", "qemu-img", "xorriso", "curl"):
        if not shutil.which(command):
            raise ValueError("Missing required command: " + command)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keeping staging beside the output makes each final rename atomic.
    with tempfile.TemporaryDirectory(prefix=".vm-image-", dir=output.parent) as temp:
        work = Path(temp)
        seed = work / "seed"
        (seed / "runtime").mkdir(parents=True)
        (seed / "zips").mkdir()
        archive = seed / "zips" / ("unRAIDServer-" + lock["version"] + "-x86_64.zip")
        if args.unraid_zip:
            shutil.copyfile(args.unraid_zip, archive)
        else:
            run("curl", "--fail", "--location", "--proto", "=https", "--proto-redir",
                "=https", "--retry", "3", "--output", archive, lock["url"])
        verify_zip(archive, lock["sha256"])
        (seed / "runtime" / "menu.sh").write_text(GUEST_MENU)
        for helper in ("vm-boot-identity.sh", "disk_identity.sh"):
            shutil.copyfile(REPO / "scripts" / helper, seed / "runtime" / helper)
        seed_iso = work / "seed.iso"
        run("xorriso", "-as", "mkisofs", "-quiet", "-V", "INSTALL-PERSIST",
            "-o", seed_iso, seed)
        for name in ("vmlinuz", "initrd"):
            run("xorriso", "-osirrox", "on", "-indev", args.iso.resolve(),
                "-extract", "/boot/" + name, work / name)
        raw = work / "boot.raw"
        run("qemu-img", "create", "-f", "raw", raw, str(args.disk_mib) + "M")
        # QEMU key-value options escape commas by doubling them.
        qpath = lambda path: str(path).replace(",", ",,")
        command = [
            "qemu-system-x86_64", "-machine", "q35,accel=" + args.accel,
            "-cpu", "host" if args.accel == "kvm" else "max", "-m", str(args.ram_mib),
            "-smp", "2", "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-no-reboot", "-nic", "none", "-kernel", str(work / "vmlinuz"),
            "-initrd", str(work / "initrd"), "-append",
            "root=/dev/ram0 rw rdinit=/init loglevel=3 console=ttyS0 consoleblank=0",
            "-drive", "file=" + qpath(args.iso.resolve()) + ",media=cdrom,format=raw,readonly=on",
            "-drive", "file=" + qpath(seed_iso) + ",format=raw,if=none,readonly=on,id=seed",
            "-device", "virtio-blk-pci,drive=seed,serial=UNRAID_INSTALLER_SEED",
            "-drive", "file=" + qpath(raw) + ",format=raw,if=none,id=boot",
            "-device", "nvme,drive=boot,serial=" + SERIAL,
        ]
        print("Installing Unraid in a private VM. Log: " + str(log_path), flush=True)
        with log_path.open("wb") as log:
            with subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT) as guest:
                try:
                    status = guest.wait(timeout=args.timeout)
                finally:
                    if guest.poll() is None:
                        guest.terminate()
                        try:
                            guest.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            guest.kill()
                            guest.wait()
        if status != 0 or "\nUNRAID_VM_BUILD_RESULT=success\n" not in log_path.read_text(errors="replace"):
            raise ValueError("Installer VM failed; inspect " + str(log_path))
        selected, method, sizes = compress_image(raw, work, args.compression)
        digest = sha256(selected)
        manifest = {
            "schema": "unraid-vm-image/v1", "kind": "installed-internal-boot",
            "filename": output.name, "format": "qcow2", "sha256": digest,
            "sizeBytes": selected.stat().st_size, "virtualSizeBytes": raw.stat().st_size,
            "compression": method, "compressionSizeBytes": sizes,
            "unraidVersion": lock["version"], "releaseZipSha256": lock["sha256"],
            "installerIsoSha256": sha256(args.iso),
            "hardware": {"architecture": "x86_64", "machine": "q35", "firmware": "uefi",
                         "secureBoot": False, "memoryMiB": args.ram_mib,
                         "bootDisk": {"bus": "nvme", "identity": "detected-before-management-start"}},
            "qaVmBootMedia": {"id": "unraid-vm", "format": "qcow2", "bus": "nvme",
                              "sourceRef": output.name, "sha256": digest},
            "licenseIncluded": False,
            "validation": {"installerCompleted": True, "qcow2Check": True,
                           "rawCompare": True, "firmwareBootTested": False},
        }
        metadata = work / "manifest.json"
        checksum = work / "checksum.sha256"
        metadata.write_text(json.dumps(manifest, indent=2) + "\n")
        checksum.write_text(digest + "\n")
        # Publish the disk last. A failed build preserves any previous disk.
        os.replace(metadata, outputs[1])
        os.replace(checksum, outputs[2])
        os.replace(selected, output)
        print("Built " + str(output) + " (" + method + ", " + str(manifest["sizeBytes"]) + " bytes)")


def positive_int(value):
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iso", type=Path, required=True, help="Installer ISO built from this source")
    parser.add_argument("--unraid-zip", type=Path, help="Local ZIP matching the release lock; otherwise download")
    parser.add_argument("--release-lock", type=Path, default=REPO / "build/unraid-release-lock.json")
    parser.add_argument("--output", type=Path, default=REPO / "zfs-live-build/unraid-vm.qcow2")
    parser.add_argument("--disk-mib", type=positive_int, default=8192, help="Virtual disk capacity (default 8192, minimum 4096)")
    parser.add_argument("--ram-mib", type=positive_int, default=8192)
    parser.add_argument("--timeout", type=positive_int, default=1800, help="Installer deadline in seconds")
    parser.add_argument("--accel", choices=("kvm", "tcg"), default="kvm")
    parser.add_argument("--compression", choices=("smallest", "zlib", "zstd"), default="smallest",
                        help="smallest measures zlib and zstd QCOW2 files and keeps the smaller one")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if args.disk_mib < 4096:
        parser.error("--disk-mib must be at least 4096")
    def interrupted(signum, _frame):
        raise KeyboardInterrupt("signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    try:
        build(args)
    except KeyboardInterrupt:
        parser.exit(130, "VM image build interrupted; the private guest was stopped.\n")
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        parser.exit(1, "VM image build failed: " + str(error) + "\n")


if __name__ == "__main__":
    main()
