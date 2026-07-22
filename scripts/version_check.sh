#!/bin/bash
# Runtime update checks for the installer image and selected Unraid ZIP.

INSTALLER_RELEASES_URL="${INSTALLER_RELEASES_URL:-https://api.github.com/repos/unraid/bootable-unraid-installer/releases?per_page=100}"
UNRAID_RELEASES_URL="${UNRAID_RELEASES_URL:-https://releases.unraid.net/usb-creator}"
INSTALLER_VERSION_FILE="${INSTALLER_VERSION_FILE:-/boot/install/installer-version}"
UNRAID_MIN_VERSION="${UNRAID_MIN_VERSION:-7.3.0}"

version_check_download() {
    local url="$1" destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --connect-timeout 3 --max-time 8 --silent --show-error --fail --location "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 8 -O "$destination" "$url"
    else
        return 1
    fi
}

installer_current_version() {
    [[ -r "$INSTALLER_VERSION_FILE" ]] || return 1
    tr -d '[:space:]' < "$INSTALLER_VERSION_FILE"
}

latest_installer_version() {
    local metadata
    metadata="$(mktemp)" || return 1
    version_check_download "$INSTALLER_RELEASES_URL" "$metadata" || { rm -f "$metadata"; return 1; }
    php -r '
        $releases = json_decode(file_get_contents($argv[1]), true);
        if (!is_array($releases)) exit(1);
        $versions = [];
        foreach ($releases as $release) {
            if (($release["draft"] ?? false) || ($release["prerelease"] ?? false)) continue;
            $tag = $release["tag_name"] ?? "";
            if (preg_match("/^Installer-(\\d+(?:\\.\\d+)+)$/", $tag, $m)) $versions[] = $m[1];
        }
        if (!$versions) exit(1);
        usort($versions, "version_compare");
        echo end($versions);
    ' "$metadata"
    local rc=$?
    rm -f "$metadata"
    return "$rc"
}

selected_zip_version() {
    local zip_file="$1" base
    base="$(basename "$zip_file")"
    [[ "$base" =~ ^unRAIDServer-([0-9]+(\.[0-9]+)+)-x86_64\.zip$ ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

latest_unraid_zip_version() {
    local metadata
    metadata="$(mktemp)" || return 1
    version_check_download "$UNRAID_RELEASES_URL" "$metadata" || { rm -f "$metadata"; return 1; }
    php -r '
        $json = json_decode(file_get_contents($argv[1]), true);
        if (!is_array($json)) exit(1);
        $versions = [];
        $add = function ($entry) use (&$versions, $argv) {
            $name = $entry["name"] ?? ""; $url = $entry["url"] ?? "";
            if (preg_match("/\\b(\\d+(?:\\.\\d+)+)\\b/", $name, $m) && stripos($url, ".zip") !== false && version_compare($m[1], $argv[2], ">=")) $versions[] = $m[1];
        };
        foreach (($json["os_list"] ?? []) as $entry) {
            if (!is_array($entry)) continue;
            $add($entry);
            foreach (($entry["subitems"] ?? []) as $subitem) if (is_array($subitem)) $add($subitem);
        }
        if (!$versions) exit(1);
        usort($versions, "version_compare");
        echo end($versions);
    ' "$metadata" "$UNRAID_MIN_VERSION"
    local rc=$?
    rm -f "$metadata"
    return "$rc"
}

installer_update_warning() {
    local current latest
    current="$(installer_current_version)" || return 0
    latest="$(latest_installer_version)" || return 0
    if php -r 'exit(version_compare($argv[1], $argv[2], "<") ? 0 : 1);' "$current" "$latest"; then
        printf 'A newer Unraid ISO Installer is available (%s). This media is version %s. Download the latest installer before continuing.\n' "$latest" "$current"
    fi
}

zip_update_warning() {
    local zip_file="$1" current latest
    current="$(selected_zip_version "$zip_file")" || return 0
    latest="$(latest_unraid_zip_version)" || return 0
    if php -r 'exit(version_compare($argv[1], $argv[2], "<") ? 0 : 1);' "$current" "$latest"; then
        printf 'The selected Unraid ZIP is version %s, but version %s is available. Download the latest ZIP before creating boot media.\n' "$current" "$latest"
    fi
}
