# User Build Documentation

## Purpose

Define the build-chain behavior for user artifacts.

## Build Scope

- Build scripts generate user artifacts only.
- Partner-specific runtime behavior is not seeded by default from this build chain.
- Partner integrations may still extend the installer at runtime through persistence.

## Primary Outputs

- `zfs-live-build/install-user.iso`
- `zfs-live-build/install-user.img`
- `zfs-live-build/install-user-minimal.img` online installer image

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

Seeded public IMG artifacts also download the pinned Unraid OS ZIP from
`build/unraid-release-lock.json` into persistence at build time. This bundled
payload is approved for redistribution as part of the official installer image
because it is an alternative Unraid install method. The
`update-unraid-release-lock.yml` workflow checks for new Unraid OS releases and
opens a pull request when the pinned payload should move.

## Runtime Menu Behavior

Built user runtime launches via `/boot/install/menu.sh`.
Persistence runtime overrides under `/mnt/persist/runtime` are applied before menu launch.

## Partner Runtime Overrides

Persistence `runtime/` is an intentional trusted extension point for partner
and support workflows. Files placed under `/mnt/persist/runtime` can replace
installer runtime scripts such as `menu.sh`, `create_flash_boot.sh`, and
`zip.sh`; replacement scripts are made executable and run as root during the
installer flow. See [USER_COMMANDS.md](USER_COMMANDS.md#persistence-runtime-overrides)
for the full list of supported override names.

Treat this directory as trusted code, not as general user data. Anyone who can
write to persistence can change future installer behavior. Partner-prepared
media may use this path to customize the installer flow.

The public user build chain does not seed arbitrary top-level persistence data;
it copies only `zips/` and `logs/` from `persistent/`. Partner tooling that
prepares installer media may populate `runtime/` after the base image is built.
