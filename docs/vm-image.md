# Preinstalled Unraid VM image

The VM image boots directly into Unraid from an internal ZFS boot disk. It uses
the same `create_internal_boot_user.sh` installation path as the installer.
The existing ISO and USB images still boot the installer menu.

## Build

On a Linux build host with access to `/dev/kvm`, run:

```bash
./scripts/build-install-images.sh --mode full --vm-image --force
```

To reuse an installer ISO and a local copy of the pinned release ZIP, run:

```bash
python3 scripts/build-vm-image.py \
  --iso zfs-live-build/install-user.iso \
  --unraid-zip /path/to/unRAIDServer-7.3.2-x86_64.zip \
  --output zfs-live-build/unraid-vm.qcow2
```

Without `--unraid-zip`, the builder downloads the release in
`build/unraid-release-lock.json`. Both paths require its exact SHA-256.
The standalone builder needs Python 3, QEMU, `qemu-img`, `xorriso`, and `curl`.
Use `--accel tcg` for software emulation on a host without KVM. This is slower.

The builder exposes one private disk file to the installer VM. It does not
attach host disks. The VM has no network access. Its private seed contains the
verified release ZIP and an unattended installer script.

Outputs:

- `unraid-vm.qcow2`: the installed boot disk.
- `unraid-vm.qcow2.json`: release provenance, checksum, compression sizes, and hardware requirements.
- `unraid-vm.qcow2.sha256`: the disk's SHA-256 digest.
- `unraid-vm.qcow2.build.log`: the installer console log, also retained on failure.

The default virtual disk capacity is 4 GiB, with a dedicated boot pool.
`--disk-mib` can increase the capacity. Unused sectors do not increase the
download by the full reserved capacity.

## Compression and verification

The default `--compression smallest` builds both zlib and zstd compressed
QCOW2 files and keeps the smaller complete file. The manifest records both
sizes. This selects the smaller supported QCOW2 artifact for that build. It
does not claim a minimum across every archive or virtual disk format.

Use `--compression zlib` when the consuming QEMU build lacks zstd support.
QCOW2 supports compressed clusters without a separate extraction step, as
described in the [QEMU image utility documentation](https://www.qemu.org/docs/master/tools/qemu-img.html).

Before publication, the builder checks the exported boot pool, payload, disk
identity, and EFI loader. It runs `qemu-img check` and compares the QCOW2 disk
contents with the installed raw disk. The manifest distinguishes these checks
from a firmware boot test. A successful installer exit alone does not prove a
firmware boot.

## Boot with QEMU

Use x86-64, q35, UEFI with Secure Boot disabled, and at least 8 GiB RAM.
The image detects its boot disk from the mounted ZFS pool and refreshes the
saved pool assignment before starting management, in both normal and safe mode.
There is no required model or serial value. Give the virtual disk a stable,
nonempty serial of your choice; QA-VM supplies one automatically. NVMe is the
recommended attachment. The bootloader locates the pool by its UUID.

The identity hook changes only this image's single-device `boot` pool assignment.
If discovery is ambiguous or the disk has no usable identity, management startup
stops with a console error instead of assigning an unrelated disk. Keep the hook
in `config/go` and `config/go.safemode` if customizing startup. Attach only one
clone of this image to a VM because clones retain the same ZFS pool UUID.

Use a private writable copy or overlay for each VM. For example:

```bash
qemu-img create -f qcow2 -F qcow2 \
  -b /absolute/path/unraid-vm.qcow2 /absolute/path/session.qcow2

qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 8192 -smp 2 -vga virtio \
  -drive if=pflash,format=raw,readonly=on,file=/path/to/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/path/to/private/OVMF_VARS.fd \
  -drive file=/absolute/path/session.qcow2,format=qcow2,if=none,id=boot \
  -device nvme,drive=boot,serial=my-vm-boot,bootindex=1
```

Use a matching firmware pair and copy the variables file for each VM. The
image contains no license, credentials, data disks, or QA-specific identity.

## QA-VM import

The companion QA-VM provider change adds `qcow2` boot media on NVMe. It verifies
the source checksum and rejects external backing files, external data files,
encryption, snapshots, unsafe feature flags, and virtual disks above 64 GiB.
It converts the verified artifact to a private sparse raw disk before boot.
The distributed QCOW2 remains unchanged. Reservation release uses the normal
baseline restoration path.

Place the artifact under a configured provider artifact root. Copy the
manifest's `qaVmBootMedia` object into the reservation's complete hardware
document as `bootMedia`. Set `bootOrder` to `["unraid-vm"]`, `machine` to
`q35`, and `firmware` to `uefi`. Declare all data disks and network interfaces
in that same hardware document.

This uses the provider's boot-media session: VNC access, without automatic
guest setup, license installation, or capacity identity replacement. It does
not replace a capacity's permanent baseline. Read the running provider's
embedded skill for supported reservation and cleanup commands. Older providers
reject `qcow2`; raw/ISO-only providers need the companion update.

Release builds publish `unraid-vm-<installer-version>.qcow2` and its manifest
and checksums alongside the existing installer downloads.
