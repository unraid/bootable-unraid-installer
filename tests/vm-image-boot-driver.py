#!/usr/bin/env python3
"""Firmware-boot a released VM disk, then relocate it to different hardware."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid


SCENARIOS = (
    ("nvme", "nvme,drive=boot,serial=E2E_CHANGED_NVME,bootindex=1",
     "nvme0n1", "QEMU_NVMe_Ctrl_E2E_CHANGED_NVME"),
    ("sata", "ide-hd,drive=boot,bus=ide.0,model=Portable Boot Disk,serial=E2E_CHANGED_SATA,bootindex=1",
     "sda", "Portable_Boot_Disk_E2E_CHANGED_SATA"),
)
EXPECTED_BYTES = 8 * 1024 ** 3


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


class QMP:
    def __init__(self, path, deadline, guest):
        while time.monotonic() < deadline:
            if guest.poll() is not None:
                raise RuntimeError("QEMU exited before its monitor became available")
            self.socket = socket.socket(socket.AF_UNIX)
            self.socket.settimeout(15)
            try:
                self.socket.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.socket.close()
                time.sleep(0.25)
        else:
            raise TimeoutError("QMP connection deadline exceeded")
        self.stream = self.socket.makefile("rwb")
        self.stream.readline()
        self.command("qmp_capabilities")

    def command(self, name, arguments=None):
        message = {"execute": name}
        if arguments is not None:
            message["arguments"] = arguments
        self.stream.write((json.dumps(message) + "\n").encode())
        self.stream.flush()
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("QMP closed unexpectedly")
            response = json.loads(line)
            if "error" in response:
                raise RuntimeError(response["error"])
            if "return" in response:
                return response["return"]

    def type(self, value, deadline):
        keys = {" ": "spc", "\n": "ret", "-": "minus", "_": "shift-minus",
                ".": "dot", "/": "slash", "=": "equal", "'": "apostrophe",
                '"': "shift-apostrophe", ">": "shift-dot", "<": "shift-comma",
                ":": "shift-semicolon", ";": "semicolon", "|": "shift-backslash",
                "^": "shift-6", "$": "shift-4", "(": "shift-9", ")": "shift-0", "&": "shift-7",
                "{": "shift-bracket_left", "}": "shift-bracket_right"}
        for character in value:
            if time.monotonic() >= deadline:
                raise TimeoutError("Guest input deadline exceeded")
            key = keys.get(character, character)
            if character.isupper():
                key = "shift-" + character.lower()
            response = self.command("human-monitor-command", {"command-line": "sendkey " + key + " 10"})
            if response:
                raise RuntimeError(response)
            time.sleep(0.2)  # Allow key release even under software emulation.

    def close(self):
        self.stream.close()
        self.socket.close()


def wait_screen(qmp, guest, screenshot, pattern, deadline):
    """OCR only locates console prompts; guest assertions decide success."""
    while time.monotonic() < deadline:
        if guest.poll() is not None:
            raise RuntimeError("Guest exited before reaching " + pattern)
        qmp.command("screendump", {"filename": str(screenshot)})
        output = run("tesseract", screenshot, "stdout", "--psm", "6",
                     capture_output=True, text=True, timeout=30).stdout
        screenshot.with_suffix(".txt").write_text(output)
        if re.search(pattern, output):
            return
        time.sleep(2)
    raise TimeoutError("Console never reached " + pattern)


def boot(args, work, overlay, scenario):
    name, device, disk, identity = scenario
    deadline = time.monotonic() + args.timeout
    serial = args.state_dir / (name + "-serial.log")
    screenshot = args.state_dir / (name + "-console.ppm")
    variables = work / "vars.fd"
    shutil.copyfile(args.firmware_vars, variables)
    monitor = work / "qmp.sock"
    monitor.unlink(missing_ok=True)
    qpath = lambda path: str(path).replace(",", ",,")
    command = ["qemu-system-x86_64", "-machine", "q35,accel=" + args.accel,
               "-cpu", "host" if args.accel == "kvm" else "max", "-m", str(args.ram),
               "-smp", str(args.cpus), "-vga", "virtio", "-display", "none", "-nic", "none",
               "-drive", "if=pflash,format=raw,readonly=on,file=" + qpath(args.firmware_code),
               "-drive", "if=pflash,format=raw,file=" + qpath(variables),
               "-drive", "if=none,id=boot,format=qcow2,file=" + qpath(overlay),
               "-device", device, "-serial", "file:" + str(serial),
               "-qmp", "unix:" + str(monitor) + ",server=on,wait=off"]
    qmp = None
    with (args.state_dir / (name + "-qemu.log")).open("wb") as log:
        guest = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            qmp = QMP(monitor, deadline, guest)
            wait_screen(qmp, guest, screenshot, r"login:\s*", deadline)
            qmp.type("root\n", deadline)
            wait_screen(qmp, guest, screenshot, r"root@", deadline)
            # Read real guest state. Do not execute the identity helper ourselves:
            # a missing/broken production startup hook must fail this test.
            token = "UNRAID_VM_E2E_PASS_" + uuid.uuid4().hex
            part = disk + ("p3" if disk[-1].isdigit() else "3")
            probe = ("{ set -x; test \"$(blockdev --getsize64 /dev/" + disk + ")\" = " + str(EXPECTED_BYTES)
                     + " && test \"$(blockdev --getsize64 /dev/" + part + ")\" -gt 7516192768"
                     + " && grep '^diskId=' /boot/config/pools/boot.cfg"
                     + " && grep '^diskId=' /boot/config/pools/boot.cfg | cut -d '\"' -f 2 | grep -Fqx '" + identity + "'"
                     + " && zpool status -x flash | grep -q 'is healthy'"
                     + " && pgrep -x emhttpd && echo " + token + " || echo UNRAID_VM_E2E_FAIL; } > /dev/ttyS0 2>&1\n")
            qmp.type(probe, deadline)
            qmp.command("screendump", {"filename": str(screenshot)})
            assertion_deadline = min(deadline, time.monotonic() + 30)
            while time.monotonic() < assertion_deadline:
                transcript = serial.read_text(errors="replace")
                if "UNRAID_VM_E2E_FAIL" in transcript:
                    raise RuntimeError("Guest assertions failed; inspect " + str(serial))
                if "\n" + token + "\n" in transcript.replace("\r", ""):
                    break
                if guest.poll() is not None:
                    raise RuntimeError("Guest exited before assertions completed")
                time.sleep(1)
            else:
                qmp.command("screendump", {"filename": str(screenshot)})
                raise TimeoutError("Guest assertions did not pass; inspect " + str(serial))
            # A clean shutdown persists the first assignment before relocating the
            # same overlay. This also exercises the subsequent-boot path.
            qmp.type("/sbin/shutdown -h now\n", deadline)
            shutdown_deadline = min(deadline, time.monotonic() + 300)
            while guest.poll() is None and time.monotonic() < shutdown_deadline:
                try:
                    qmp.command("screendump", {"filename": str(args.state_dir / (name + "-shutdown.ppm"))})
                except (OSError, RuntimeError):
                    if guest.poll() is None:
                        raise
                time.sleep(2)
            if guest.poll() is None:
                raise TimeoutError("Guest shutdown deadline exceeded; inspect shutdown capture")
            if guest.returncode != 0:
                raise RuntimeError("QEMU did not exit cleanly after guest shutdown")
            result = {"scenario": name, "diskIdentity": identity, "virtualSizeBytes": EXPECTED_BYTES,
                      "bootPoolPartitionMinimumBytes": 7516192768, "passed": True}
            (args.state_dir / (name + "-result.json")).write_text(json.dumps(result, indent=2) + "\n")
            print("Passed firmware boot and guest assertions: " + name, flush=True)
            return result
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    guest.kill()
                    guest.wait()
            if qmp:
                qmp.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm-image", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--accel", choices=("kvm", "tcg"), default="kvm")
    parser.add_argument("--ram", type=int, default=8192)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=1200, help="Deadline per boot in seconds")
    parser.add_argument("--firmware-code", type=Path, default=Path("/usr/share/OVMF/OVMF_CODE_4M.fd"))
    parser.add_argument("--firmware-vars", type=Path, default=Path("/usr/share/OVMF/OVMF_VARS_4M.fd"))
    args = parser.parse_args()
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt("E2E interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    for key in ("vm_image", "state_dir", "firmware_code", "firmware_vars"):
        setattr(args, key, getattr(args, key).resolve())
    for command in ("qemu-system-x86_64", "qemu-img", "tesseract"):
        if not shutil.which(command):
            parser.error("Missing command: " + command)
    if min(args.ram, args.cpus, args.timeout) <= 0:
        parser.error("RAM, CPU count, and deadline must be positive")
    if args.state_dir.exists() and any(args.state_dir.iterdir()):
        parser.error("Use a new, empty --state-dir to preserve previous evidence")
    if not args.vm_image.is_file() or not args.firmware_code.is_file() or not args.firmware_vars.is_file():
        parser.error("The image and both firmware inputs must be regular files")
    args.state_dir.mkdir(parents=True, exist_ok=True)
    original = digest(args.vm_image)
    info = json.loads(run("qemu-img", "info", "-f", "qcow2", "--output=json", args.vm_image,
                          capture_output=True, text=True).stdout)
    if info["virtual-size"] != EXPECTED_BYTES or info.get("backing-filename"):
        parser.error("Expected a standalone image with the default 8 GiB capacity")
    try:
        # Short QMP socket path also works on hosts with long workspace paths.
        with tempfile.TemporaryDirectory(prefix="vm-e2e-") as temporary:
            work = Path(temporary)
            overlay = work / "session.qcow2"
            run("qemu-img", "create", "-f", "qcow2", "-F", "qcow2", "-b", args.vm_image, overlay)
            results = [boot(args, work, overlay, scenario) for scenario in SCENARIOS]
        (args.state_dir / "result.json").write_text(json.dumps({"sha256": original, "scenarios": results}, indent=2) + "\n")
    finally:
        if digest(args.vm_image) != original:
            raise RuntimeError("E2E modified the distributed image")
    print("VM image E2E passed; original artifact preserved and test guests stopped.")


if __name__ == "__main__":
    main()
