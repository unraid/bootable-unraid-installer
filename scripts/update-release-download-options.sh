#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Update a GitHub release body with the managed installer download options section.

Usage:
  update-release-download-options.sh --release-tag TAG --release-version VERSION

Environment:
  GH_TOKEN or GITHUB_TOKEN must allow editing releases.
EOF
}

RELEASE_TAG=""
RELEASE_VERSION=""

while (($#)); do
  case "$1" in
    --release-tag)
      [[ $# -ge 2 ]] || { echo "Missing value for --release-tag" >&2; exit 1; }
      RELEASE_TAG="$2"
      shift 2
      ;;
    --release-version)
      [[ $# -ge 2 ]] || { echo "Missing value for --release-version" >&2; exit 1; }
      RELEASE_VERSION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$RELEASE_TAG" ]] || { echo "Missing --release-tag" >&2; exit 1; }
[[ -n "$RELEASE_VERSION" ]] || { echo "Missing --release-version" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is required" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CURRENT_BODY="$TMP_DIR/current.md"
PRESERVED_BODY="$TMP_DIR/preserved.md"
TRIMMED_BODY="$TMP_DIR/trimmed.md"
NEXT_BODY="$TMP_DIR/next.md"

gh release view "$RELEASE_TAG" --json body --jq '.body // ""' > "$CURRENT_BODY"

awk '
  /<!-- unraid-installer-download-options:start -->/ { skip = 1; next }
  /<!-- unraid-installer-download-options:end -->/ { skip = 0; next }
  !skip { print }
' "$CURRENT_BODY" > "$PRESERVED_BODY"

awk '
  NF {
    for (i = 0; i < blanks; i++) {
      print ""
    }
    blanks = 0
    print
    next
  }
  { blanks++ }
' "$PRESERVED_BODY" > "$TRIMMED_BODY"

{
  if [[ -s "$TRIMMED_BODY" ]]; then
    cat "$TRIMMED_BODY"
    printf '\n\n'
  fi

  cat <<EOF
<!-- unraid-installer-download-options:start -->
## Download Options

Choose the installer asset that matches the install path:

- **Online installer**: \`unraid-installer-${RELEASE_VERSION}-online.iso\` or \`unraid-installer-${RELEASE_VERSION}-online.img.zip\`. This is the smaller download. It boots the installer and downloads Unraid OS during installation, so the target system needs network access.
- **Bundled installer**: \`unraid-installer-${RELEASE_VERSION}-bundled.img.zip\`. This is the larger download because it includes the pinned Unraid OS payload. Use it when the installer media should already contain the approved Unraid OS ZIP.
- **Hetzner Rescue**: download \`unraid-installer-hetzner-rescue.sh\` from this release and run it with one or two stable \`/dev/disk/by-id\` paths. The launcher downloads and SHA256-verifies this release's online ISO automatically.
- **Checksums**: each downloadable asset has matching \`.md5\` and \`.sha256\` files.

Bundled assets are retained only for the latest stable \`Installer-*\` release. Older and prerelease installer releases may provide only the online installer path.
<!-- unraid-installer-download-options:end -->
EOF
} > "$NEXT_BODY"

gh release edit "$RELEASE_TAG" --notes-file "$NEXT_BODY"
