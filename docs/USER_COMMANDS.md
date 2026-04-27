# Onboarding Commands and Script Options

This guide lists the current user build chain commands.

## Quick Start

Build user artifacts and overwrite previous outputs:

```bash
./build-install-images.sh --mode full --force
```

Artifacts are produced in `zfs-live-build/` and copied to `artifacts/published/` when publish is enabled.

## GitHub Actions Build Process

Workflow file:

- `.github/workflows/build-images.yml`

Runner requirement:

- GitHub-hosted runner: `ubuntu-24.04`

### Run User Automation Build

Use this for the standard automated media build.

- Open GitHub Actions and select `Build Onboarding Images`.
- Click `Run workflow` with these inputs: `profile=user`, `mode=full`, `menu_ui=gui`, `clean_build=false`, `force=true`, `publish=false`.
- Start the run and wait for completion.
- Download artifact `onboarding-user-images-<run_number>`.

Expected artifact contents:

- `install-user.iso`
- `install-user.img`
- `install-user-minimal.img` (if built)
- `checksums.sha256`

## Core Build Scripts

### `build-install-images.sh`

Purpose:

- Build user ISO and IMG artifacts.
- Publish copies to `artifacts/published/` by default (or `PUBLISH_DIR`).

Usage:

```bash
./build-install-images.sh [--user] [--mode full|grub-iso] [--menu-ui gui] [--persist-fs ext4|fat32|vfat] [--size SIZE] [--clean-build] [--force]
```

Options:

- `--user`: accepted alias for user-only flow
- `--mode MODE`: first run mode, `full` or `grub-iso` (default `full`)
- `--menu-ui UI`: default menu implementation, `gui` only
- `--persist-fs FS`: default persistence filesystem for boot auto-create (`ext4|fat32|vfat`)
- `--size SIZE`: image size passed to `build-usb-native.sh` (default `auto`)
- `--clean-build`: force clean kernel/ZFS rebuild (requires `--mode full`)
- `--force`: overwrite existing outputs

Environment:

- `PUBLISH_DIR`: publish destination (default `./artifacts/published`)

Outputs in repo:

- `zfs-live-build/install-user.iso`
- `zfs-live-build/install-user.img`
- `zfs-live-build/install-user-minimal.img`

Published outputs:

- `artifacts/published/install-user.iso`
- `artifacts/published/install-user.img`
- `artifacts/published/install-user-minimal.img`

### `build-iso.sh`

Purpose:

- Build onboarding ISO (kernel/rootfs/initramfs/GRUB pipeline).

Usage:

```bash
./build-iso.sh [full|grub-iso|cache-only] [--clean] [--menu-ui gui] [--persist-fs ext4|fat32|vfat] [--persist-recreate-on-resize-fail]
```

Modes:

- `full`: full kernel/ZFS/rootfs build path
- `grub-iso`: reuse existing built assets and rebuild ISO layer
- `cache-only`: refresh kernel/OpenZFS cache artifacts only

Key environment variables:

- `PUBLISH_ISO=/path/to/output.iso`
- `KERNEL_SERIES` (default `6.18`)
- `KERNEL_VERSION` (optional exact version or series)
- `UBUNTU_CODENAME`, `UBUNTU_MIRROR`, `UBUNTU_SECURITY_MIRROR`

Examples:

```bash
PUBLISH_ISO=./zfs-live-build/install-user.iso ./build-iso.sh full --menu-ui gui
PUBLISH_ISO=./zfs-live-build/install-user.iso ./build-iso.sh grub-iso --menu-ui gui
```

### `build-usb-native.sh`

Purpose:

- Create a native GPT USB image from an ISO with optional persistence partition.

Usage:

```bash
./build-usb-native.sh [--iso PATH] [--output PATH] [--size SIZE|auto] [--persist-fs ext4|exfat|fat32|vfat] [--seed-dir PATH] [--no-persist] [--force]
```

Notes:

- User build chain seeding copies only top-level `zips/` and `logs/` from the seed source.
- Runtime overrides are applied at boot from `/mnt/persist/runtime`.

## USB and Packaging Helpers

### Write IMG to USB Device

Use the generated `.img` when possible.

Linux/macOS (`dd`):

```bash
sudo dd if=./zfs-live-build/install-user.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

If you need to write ISO directly:

```bash
sudo dd if=./zfs-live-build/install-user.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Windows:

- Use Rufus or Balena Etcher.
- Select `install-user.img` (preferred) or `install-user.iso`.
- If writing ISO with Rufus, use DD Image mode when prompted.

### `write-usb.sh`

Purpose:

- Write ISO to a physical USB disk and create/configure persistence partition.

Usage:

```bash
./write-usb.sh <device> [iso_path] [zip_path]
```

Examples:

```bash
./write-usb.sh sdb
./write-usb.sh /dev/sdb ./zfs-live-build/install-user.iso
./write-usb.sh /dev/sdb ./zfs-live-build/install-user.iso /path/to/unRAIDServer-7.2.4-x86_64.zip
```

### `zip.sh`

Purpose:

- Download/select Unraid ZIP payloads into persistence storage.

Usage:

```bash
./zip.sh [--zip-dir PATH]
```

## Runtime Menu Scripts

Runtime uses GUI-first menu scripts:

- `menu_gui_user.sh`: base user onboarding menu

At runtime, `/boot/install/menu.sh` is launched after persistence runtime overrides are applied.

## Common Troubleshooting

1. Kernel/ZFS did not rebuild:

```bash
rm -f zfs-live-build/.kernel-build-*.stamp zfs-live-build/.zfs-build-*.stamp
./build-install-images.sh --mode full --force
```

1. Full clean rebuild:

```bash
rm -rf zfs-live-build
./build-install-images.sh --mode full --force
```
