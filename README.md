# unraid-installer Documentation

This repository contains build and packaging scripts for creating Unraid installer media.

The toolchain focuses on producing bootable installer artifacts (ISO and IMG), plus helper assets used by the installer runtime.

## What This Repo Does

- Builds installer images from script-driven workflows.
- Produces ISO and USB-ready IMG outputs.
- Packages persistent seed content used by installer media.
- Provides utility scripts for dependencies, kernel/ZFS cache builds, and boot media setup.
- Uses Release Please to version the installer and publish assets built from the exact release tag.

## Repo Areas

- `scripts/`: build and packaging entry points.
- `persistent/`: seed content included in media builds.
- `build/`: generated metadata (for example, version lock files).
- `docs/`: user-facing documentation for build usage.

## Documentation Index

Start here, then use the detailed guides below:

1. `docs/USER_GUIDE.md`
   - User guide for choosing an installer asset, booting the tool, and creating
     flash or internal boot devices.
2. `docs/user-build.md`
   - High-level build-chain scope, outputs, and script responsibilities.
3. `docs/USER_COMMANDS.md`
   - Command reference, build modes, common options, and troubleshooting.
4. `docs/linux-rescue-install.md`
   - Linux Rescue and temporary-QEMU workflow for installing to physical disks
     without persisting virtual disk identities. Hetzner is the first validated
     provider.

The Rescue-side entry point for that workflow is
`scripts/linux-rescue-vm.sh`.

## Typical Build Entry Point

From the repository root:

```bash
./scripts/build-install-images.sh --mode full --force
```

Primary outputs are typically written under `zfs-live-build/`.

## License and Security

This repository is licensed under GPL-2.0-or-later. See `LICENSE`.

Please report suspected vulnerabilities through the Unraid organization
security policy: <https://github.com/unraid/.github/security/policy>.

## Notes

- Script behavior and options can evolve. Use `docs/USER_COMMANDS.md` as the primary reference for current command usage.
- If a docs link or path drifts, update this index first so onboarding starts from a reliable source.
