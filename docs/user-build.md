# User Build Documentation

## Purpose

Define the build-chain behavior for user artifacts.

## Build Scope

- Build scripts generate user artifacts only.
- Partner-specific runtime behavior is not part of the build chain.

## Primary Outputs

- `zfs-live-build/install-user.iso`
- `zfs-live-build/install-user.img`
- `zfs-live-build/install-user-minimal.img`

## Build Entry Point

Use:

- `scripts/build-install-images.sh`

Example:

```bash
./scripts/build-install-images.sh --mode full --force
```

## Script Responsibilities

- `scripts/build-install-images.sh`: orchestrates user artifact builds.
- `scripts/build-iso.sh`: assembles user runtime payload into ISO.
- `scripts/build-usb-native.sh`: creates user USB image and seeds user-build persistence data.

## Persistence Seeding in Build Chain

The user build chain seeds only top-level allowed items from `persistent/`:

- `zips`
- `logs`

All other top-level seed items are skipped by design.

## Runtime Menu Behavior

Built user runtime launches via `/boot/install/menu.sh`.
Persistence runtime overrides under `/mnt/persist/runtime` are applied before menu launch.
