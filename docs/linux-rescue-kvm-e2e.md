# Reusable Linux Rescue KVM E2E Test

This repository includes a destructive, provider-neutral harness for testing
the complete Linux Rescue installation path on a disposable Linux machine. It
starts the released installer ISO through the same Rescue launcher users run,
keeps the normal VNC installer menu visible, and verifies the installed disks
after the temporary guest stops.

Do not run this test on production disks. The two target devices are erased.
The harness requires the exact environment value
`UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS` before it will launch QEMU.

## Requirements

The test host needs:

- Linux with `/dev/kvm` and enough memory for a 4 GiB nested guest;
- two disposable whole block devices of at least 32 GiB;
- QEMU, OVMF, udev, and either QEMU user networking, `passt`, or an existing
  Linux bridge;
- VNC access through localhost or an SSH tunnel; and
- `zpool`, `zfs`, `mtools`, `gdisk`, `util-linux`, and `parted` for post-install
  verification.

The harness is intentionally not part of ordinary GitHub-hosted CI. It needs
KVM, raw disposable disks, and an operator-visible destructive confirmation.
The shell itself is covered by the normal ShellCheck workflow.

## Launch

Build or download an installer ISO, identify two disposable disks by stable
device paths, and run:

```bash
sudo UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS \
  tests/linux-rescue-kvm-e2e.sh launch \
  --iso /root/install-user.iso \
  --disk /dev/disk/by-id/<first-test-disk> \
  --disk /dev/disk/by-id/<second-test-disk>
```

On a host where QEMU has no usable `user` or `passt` backend, explicitly name
an existing test bridge:

```bash
sudo UNRAID_RESCUE_E2E_CONFIRM=ERASE_DISPOSABLE_DISKS \
  tests/linux-rescue-kvm-e2e.sh launch \
  --iso /root/install-user.iso \
  --disk /dev/sdl \
  --disk /dev/sdm \
  --bridge br0
```

The harness records the normalized host disk paths under
`/root/unraid-installer-e2e`, so later phases do not need the disk arguments.
Use `--state-dir` to keep independent runs separate.

## Complete the installer menu

Forward the VNC port shown by the launcher and use the normal installer menu:

1. Download or select the intended Unraid ZIP.
2. Choose **Create Internal Boot**.
3. Select **Two disks (mirrored)** with the cursor.
4. Select both disposable test disks.
5. Choose a 16,384 MiB boot-pool size and complete the operation.
6. Leave the completion dialog visible. Do not boot the installed Unraid OS
   inside the temporary guest.

Keeping this phase interactive exercises the same UI and destructive
confirmation users see. It also avoids hiding installer-menu changes behind a
blind sequence of synthesized keystrokes.

## Stop and verify

After the installer reports completion:

```bash
sudo tests/linux-rescue-kvm-e2e.sh stop
sudo tests/linux-rescue-kvm-e2e.sh verify
```

`stop` exits QEMU through its monitor and flushes both host disks. `verify`
performs read-only checks and exports the pool afterward. It verifies:

- both disks contain the EFI, ZFS boot, and p4 data partitions;
- the ZFS partitions have equal sizes;
- `flash` imports as an online two-member mirror with no known data errors;
- both `EFI/BOOT/BOOTX64.EFI` files are byte-for-byte identical;
- the installed boot-pool configuration contains the two host-visible IDs
  from the QEMU `fw_cfg` handoff; and
- no nested `QEMU_NVMe_Ctrl_*` identity was persisted.

The command prints the EFI SHA256, persisted IDs, and final partition layout
as evidence suitable for a pull-request verification section.
