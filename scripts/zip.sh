#!/bin/bash

set -euo pipefail

JSON_URL="https://releases.unraid.net/usb-creator"
MIN_VERSION="7.3.0"
ZIP_ROOT="${PERSISTENT_ROOT:-/mnt/persist}"
ZIP_DIR="${PERSISTENT_ZIP_DIR:-${ZIP_ROOT}/zips}"
LEGACY_ZIP_DIR="${ZIP_ROOT}/zip"
ZIP_DIR_OVERRIDE=""
UI_MODE="${UI_MODE:-text}"
ui_backend="text"
LATEST_ONLY=0
NON_INTERACTIVE=0

memory_zip_dir() {
  if [[ -d /run && -w /run ]]; then
    printf '%s\n' "/run/onboarding-zips"
    return 0
  fi
  printf '%s\n' "/tmp/onboarding-zips"
}

usage() {
  cat <<'EOF'
Usage: zip.sh [--zip-dir PATH]

Options:
  --zip-dir PATH   Store downloaded zip files in PATH instead of persistence mount.
  --ui MODE        UI mode: text or gui (default: text)
  --latest         Download the latest available release >= MIN_VERSION and exit.
  --non-interactive  Disable prompts; requires --latest.
  -h, --help       Show this help.
EOF
}

detect_ui_backend() {
  local preferred="${MENU_BACKEND:-}"

  if [[ "$UI_MODE" != "gui" ]]; then
    ui_backend="text"
    return
  fi

  case "${preferred,,}" in
    whiptail)
      if command -v whiptail >/dev/null 2>&1; then
        ui_backend="whiptail"
        return
      fi
      ;;
    dialog)
      if command -v dialog >/dev/null 2>&1; then
        ui_backend="dialog"
        return
      fi
      ;;
    text)
      ui_backend="text"
      return
      ;;
    "")
      ;;
    *)
      echo "Ignoring unknown MENU_BACKEND '$preferred' (expected: whiptail|dialog|text)." >&2
      ;;
  esac

  if command -v whiptail >/dev/null 2>&1; then
    ui_backend="whiptail"
    return
  fi
  if command -v dialog >/dev/null 2>&1; then
    ui_backend="dialog"
    return
  fi
  ui_backend="text"
}

ui_prompt() {
  local title="$1" prompt="$2" default_value="${3:-}"

  case "$ui_backend" in
    whiptail)
      whiptail --title "$title" --inputbox "$prompt" 12 80 "$default_value" 3>&1 1>&2 2>&3 || true
      ;;
    dialog)
      local out
      out="$(dialog --title "$title" --inputbox "$prompt" 12 80 "$default_value" 3>&1 1>&2 2>&3)" || true
      clear
      printf '%s\n' "$out"
      ;;
    *)
      local ans
      if [[ -n "$default_value" ]]; then
        read -r -p "$prompt (default: $default_value): " ans || true
        printf '%s\n' "${ans:-$default_value}"
      else
        read -r -p "$prompt: " ans || true
        printf '%s\n' "$ans"
      fi
      ;;
  esac
}

ui_confirm() {
  local title="$1" prompt="$2" default="${3:-n}" ans hint

  case "$ui_backend" in
    whiptail)
      if [[ "$default" == "n" ]]; then
        whiptail --title "$title" --defaultno --yesno "$prompt" 12 80
      else
        whiptail --title "$title" --yesno "$prompt" 12 80
      fi
      return $?
      ;;
    dialog)
      if [[ "$default" == "n" ]]; then
        dialog --title "$title" --defaultno --yesno "$prompt" 12 80
      else
        dialog --title "$title" --yesno "$prompt" 12 80
      fi
      local rc=$?
      clear
      return "$rc"
      ;;
    *)
      if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
      read -r -p "$prompt $hint: " ans || true
      ans="${ans,,}"
      [[ -z "$ans" ]] && ans="$default"
      [[ "$ans" == "y" || "$ans" == "yes" ]]
      ;;
  esac
}

ui_menu_select() {
  local title="$1" prompt="$2"
  shift 2

  case "$ui_backend" in
    whiptail)
      whiptail --title "$title" --menu "$prompt" 22 100 12 "$@" 3>&1 1>&2 2>&3
      ;;
    dialog)
      local out
      out="$(dialog --title "$title" --menu "$prompt" 22 100 12 "$@" 3>&1 1>&2 2>&3)"
      local rc=$?
      clear
      [[ $rc -eq 0 ]] || return "$rc"
      printf '%s\n' "$out"
      ;;
    *)
      return 1
      ;;
  esac
}

ui_msg() {
  local title="$1" message="$2"

  case "$ui_backend" in
    whiptail)
      whiptail --title "$title" --msgbox "$message" 20 100
      ;;
    dialog)
      dialog --title "$title" --msgbox "$message" 20 100
      clear
      ;;
    *)
      echo "$message"
      ;;
  esac
}

ui_infobox() {
  local title="$1" message="$2"

  case "$ui_backend" in
    whiptail)
      whiptail --title "$title" --infobox "$message" 12 100
      ;;
    dialog)
      dialog --title "$title" --infobox "$message" 12 100
      ;;
    *)
      ;;
  esac
}

list_downloaded_zip_paths() {
  local roots=()
  local zips=()
  local zips_sorted_file
  local find_out_file

  roots+=("$ZIP_DIR")
  if [[ -z "$ZIP_DIR_OVERRIDE" ]] && [[ "$LEGACY_ZIP_DIR" != "$ZIP_DIR" ]]; then
    roots+=("$LEGACY_ZIP_DIR")
  fi

  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find_out_file="$(mktemp)"
    find "$root" \( -type f -o -type l \) -iname '*.zip' -print 2>/dev/null > "$find_out_file"
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      zips+=("$p")
    done < "$find_out_file"
    rm -f "$find_out_file"
  done

  if [ ${#zips[@]} -eq 0 ]; then
    return 1
  fi

  zips_sorted_file="$(mktemp)"
  printf '%s\n' "${zips[@]}" | sort -V | awk '!seen[$0]++' > "$zips_sorted_file"
  mapfile -t zips < "$zips_sorted_file"
  rm -f "$zips_sorted_file"
  printf '%s\n' "${zips[@]}"
}

while (($#)); do
  case "$1" in
    --zip-dir)
      [[ $# -ge 2 ]] || {
        echo "Error: missing value for --zip-dir"
        usage
        exit 1
      }
      ZIP_DIR_OVERRIDE="$2"
      shift 2
      ;;
    --ui)
      [[ $# -ge 2 ]] || {
        echo "Error: missing value for --ui"
        usage
        exit 1
      }
      UI_MODE="$2"
      shift 2
      ;;
    --latest)
      LATEST_ONLY=1
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

case "$UI_MODE" in
  text|gui) ;;
  *)
    echo "Error: --ui must be 'text' or 'gui'"
    exit 1
    ;;
esac

if [[ "$NON_INTERACTIVE" -eq 1 && "$LATEST_ONLY" -ne 1 ]]; then
  echo "Error: --non-interactive requires --latest"
  exit 1
fi

detect_ui_backend

if [[ -n "$ZIP_DIR_OVERRIDE" ]]; then
  ZIP_DIR="$ZIP_DIR_OVERRIDE"
fi

require_persistent_zip_dir() {
  if [[ -n "$ZIP_DIR_OVERRIDE" ]]; then
    mkdir -p "$ZIP_DIR" || {
      echo "Error: unable to create ZIP path override: ${ZIP_DIR}"
      exit 1
    }
    return 0
  fi

  if [[ "${PERSIST_READY:-0}" != "1" ]]; then
    # In some launch paths PERSIST_READY is not exported even though /mnt/persist is mounted.
    # Prefer the real persistent ZIP location when it exists.
    if [[ -d "$ZIP_ROOT" ]] && { mountpoint -q "$ZIP_ROOT" 2>/dev/null || [[ -d "$ZIP_DIR" || -d "$LEGACY_ZIP_DIR" ]]; }; then
      mkdir -p "$ZIP_DIR" || {
        echo "Error: unable to create ZIP path: ${ZIP_DIR}"
        exit 1
      }
      return 0
    fi

    ZIP_DIR="$(memory_zip_dir)"
    mkdir -p "$ZIP_DIR" || {
      echo "Error: unable to create in-memory ZIP path: ${ZIP_DIR}"
      exit 1
    }
    echo "Persistent storage is not mounted. Using in-memory ZIP path: ${ZIP_DIR}"
    return 0
  fi

  mkdir -p "$ZIP_DIR" || {
    echo "Error: unable to create ZIP path: ${ZIP_DIR}"
    exit 1
  }
}

require_persistent_zip_dir

if command -v numfmt >/dev/null 2>&1; then
  HAS_NUMFMT=1
else
  HAS_NUMFMT=0
fi

format_bytes() {
  local bytes="${1:-0}"
  if [[ "$HAS_NUMFMT" -eq 1 ]]; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    printf '%s KB' "$(( bytes / 1024 ))"
  fi
}

show_downloaded_zips() {
  local zips=()
  local zips_file
  zips_file="$(mktemp)"
  if list_downloaded_zip_paths > "$zips_file"; then
    mapfile -t zips < "$zips_file"
  fi
  rm -f "$zips_file"

  if [ ${#zips[@]} -eq 0 ]; then
    if [[ "$ui_backend" != "text" ]]; then
      ui_msg "Downloaded ZIP Files" "Downloaded zip files: none"
    else
      echo "Downloaded zip files: none"
    fi
    return 1
  fi

  if [[ "$ui_backend" != "text" ]]; then
    local listing="Downloaded zip files:\n\n"
    for i in "${!zips[@]}"; do
      listing+="$(printf '%2d) %s\\n' "$((i + 1))" "$(basename "${zips[$i]}")")"
    done
    ui_msg "Downloaded ZIP Files" "$listing"
  else
    echo "Downloaded zip files:"
    for i in "${!zips[@]}"; do
      printf '%2d) %s\n' "$((i + 1))" "$(basename "${zips[$i]}")"
    done
  fi
  return 0
}

maybe_remove_downloaded_zip() {
  while true; do
    echo
    if ! show_downloaded_zips; then
      break
    fi

    if ! ui_confirm "Remove Zip" "Remove a downloaded zip file?" "n"; then
      break
    fi

    local zips=()
    local zips_file
    zips_file="$(mktemp)"
    if list_downloaded_zip_paths > "$zips_file"; then
      mapfile -t zips < "$zips_file"
    fi
    rm -f "$zips_file"
    [[ ${#zips[@]} -gt 0 ]] || break

    if [[ "$ui_backend" != "text" ]]; then
      local menu_args=() remove_choice_index="" remove_choice_path="" i
      for i in "${!zips[@]}"; do
        z="${zips[$i]}"
        menu_args+=("$((i + 1))" "$(basename "$z")")
      done
      remove_choice_index="$(ui_menu_select "Remove Zip" "Select a downloaded zip to remove" "${menu_args[@]}")" || break
      [[ "$remove_choice_index" =~ ^[0-9]+$ ]] || break
      if [[ "$remove_choice_index" -lt 1 || "$remove_choice_index" -gt ${#zips[@]} ]]; then
        break
      fi
      remove_choice_path="${zips[$((remove_choice_index - 1))]}"
      rm -f "$remove_choice_path"
      ui_msg "Remove Zip" "Removed: $(basename "$remove_choice_path")"
    else
      while true; do
        remove_index="$(ui_prompt "Remove Zip" "Enter file number to remove (or 0 to cancel)")"
        if [[ "$remove_index" =~ ^[0-9]+$ ]]; then
          if [ "$remove_index" -eq 0 ]; then
            break
          fi
          if [ "$remove_index" -ge 1 ] && [ "$remove_index" -le ${#zips[@]} ]; then
            rm -f "${zips[$((remove_index - 1))]}"
            echo "Removed: $(basename "${zips[$((remove_index - 1))]}")"
            break
          fi
        fi
        echo "Invalid selection. Enter a number between 1 and ${#zips[@]}, or 0 to cancel."
      done
    fi
  done
}

if [[ "$NON_INTERACTIVE" -ne 1 ]]; then
  maybe_remove_downloaded_zip
fi

TMP_JSON="$(mktemp)"
cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

download_file() {
  local url="$1"
  local out="$2"
  local show_progress="${3:-no}"

  if [[ "$show_progress" != "yes" ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$out"
      return
    fi
    if command -v wget >/dev/null 2>&1; then
      wget -qO "$out" "$url"
      return
    fi
    echo "Error: curl or wget is required to download files."
    exit 1
  fi

  local tmp_out="${out}.part"
  local start_ts elapsed size rate spinner_index spinner_char
  local spinner="|/-\\"
  local gui_status_shown=0

  rm -f "$tmp_out"

  if command -v curl >/dev/null 2>&1; then
    curl -fLsL "$url" -o "$tmp_out" &
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_out" "$url" &
  else
    echo "Error: curl or wget is required to download files."
    exit 1
  fi

  local dl_pid=$!
  start_ts=$(date +%s)
  spinner_index=0

  while kill -0 "$dl_pid" 2>/dev/null; do
    size=$(stat -c%s "$tmp_out" 2>/dev/null || echo 0)
    elapsed=$(( $(date +%s) - start_ts ))
    if [ "$elapsed" -lt 1 ]; then
      elapsed=1
    fi
    rate=$(( size / elapsed ))
    spinner_char=${spinner:spinner_index:1}
    spinner_index=$(( (spinner_index + 1) % 4 ))
    if [[ "$ui_backend" != "text" ]]; then
      if [[ "$gui_status_shown" -eq 0 ]]; then
        ui_infobox "Download Progress" "Downloading...\n\nPlease wait while the ZIP file is downloaded."
        gui_status_shown=1
      fi
    else
      printf '\rDownloading... %s written (%s/s) %3ss %s' "$(format_bytes "$size")" "$(format_bytes "$rate")" "$elapsed" "$spinner_char"
    fi
    sleep 1
  done

  if ! wait "$dl_pid"; then
    printf '\n'
    rm -f "$tmp_out"
    echo "Error: download failed."
    exit 1
  fi

  if [[ "$ui_backend" == "text" ]]; then
    printf '\n'
  fi

  mv -f "$tmp_out" "$out"
}

release_zip_url_without_query() {
  local url="$1"
  printf '%s\n' "${url%%\?*}"
}

release_zip_filename() {
  local url="$1"
  local clean_url
  clean_url="$(release_zip_url_without_query "$url")"
  basename "$clean_url"
}

validate_release_zip_url() {
  local url="$1"
  local clean_url filename

  clean_url="$(release_zip_url_without_query "$url")"
  filename="$(basename "$clean_url")"

  if [[ "$url" == *"#"* ]]; then
    echo "Error: release URL contains a fragment, which is not allowed: ${url}"
    exit 1
  fi

  if [[ "$clean_url" != https://releases.unraid.net/dl/* ]]; then
    echo "Error: release URL must use https://releases.unraid.net/dl/: ${url}"
    exit 1
  fi

  if [[ "$clean_url" == *"/../"* || "$clean_url" == *"/./"* ]]; then
    echo "Error: release URL path contains unsupported relative path segments: ${url}"
    exit 1
  fi

  if [[ ! "$filename" =~ ^unRAIDServer-[A-Za-z0-9._-]+-x86_64\.zip$ ]]; then
    echo "Error: release URL does not reference a supported Unraid ZIP filename: ${url}"
    exit 1
  fi
}

download_release_zip() {
  local url="$1"
  local out="$2"

  validate_release_zip_url "$url"
  download_file "$url" "$out" yes
}

flush_writeback_progress() {
  local start_ts elapsed dirty_kb writeback_kb
  local max_wait_s settle_kb stable_polls stable_count timed_out
  local gui_status_shown=0

  max_wait_s="${ZIP_FLUSH_MAX_WAIT_S:-180}"
  settle_kb="${ZIP_FLUSH_SETTLE_KB:-128}"
  stable_polls="${ZIP_FLUSH_STABLE_POLLS:-5}"
  stable_count=0
  timed_out=0

  if [[ "$ui_backend" == "text" ]]; then
    echo "Flushing filesystem buffers to disk/USB..."
  fi
  start_ts=$(date +%s)
  sync &
  local sync_pid=$!

  while kill -0 "$sync_pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start_ts ))
    dirty_kb=$(awk '/^Dirty:/ {print $2}' /proc/meminfo 2>/dev/null)
    writeback_kb=$(awk '/^Writeback:/ {print $2}' /proc/meminfo 2>/dev/null)
    dirty_kb=${dirty_kb:-0}
    writeback_kb=${writeback_kb:-0}
    if [[ "$ui_backend" != "text" ]]; then
      if [[ "$gui_status_shown" -eq 0 ]]; then
        ui_infobox "Flushing Buffers" "Finalizing ZIP download...\n\nFlushing filesystem buffers to disk/USB."
        gui_status_shown=1
      fi
    else
      printf '\rFlushing... %3ds  Dirty:%6d KB  Writeback:%6d KB' "$elapsed" "$dirty_kb" "$writeback_kb"
    fi
    sleep 1
  done

  wait "$sync_pid"

  while true; do
    elapsed=$(( $(date +%s) - start_ts ))
    dirty_kb=$(awk '/^Dirty:/ {print $2}' /proc/meminfo 2>/dev/null)
    writeback_kb=$(awk '/^Writeback:/ {print $2}' /proc/meminfo 2>/dev/null)
    dirty_kb=${dirty_kb:-0}
    writeback_kb=${writeback_kb:-0}
    if [[ "$ui_backend" != "text" ]]; then
      if [[ "$gui_status_shown" -eq 0 ]]; then
        ui_infobox "Flushing Buffers" "Finalizing ZIP download...\n\nFlushing filesystem buffers to disk/USB."
        gui_status_shown=1
      fi
    else
      printf '\rFlushing... %3ds  Dirty:%6d KB  Writeback:%6d KB' "$elapsed" "$dirty_kb" "$writeback_kb"
    fi
    if [ "$dirty_kb" -eq 0 ] && [ "$writeback_kb" -eq 0 ]; then
      break
    fi

    # Some runtimes keep a small dirty/writeback floor due to background activity.
    # Treat sustained low values as flushed to avoid looping forever.
    if [ "$dirty_kb" -le "$settle_kb" ] && [ "$writeback_kb" -le "$settle_kb" ]; then
      stable_count=$((stable_count + 1))
      if [ "$stable_count" -ge "$stable_polls" ]; then
        break
      fi
    else
      stable_count=0
    fi

    if [ "$elapsed" -ge "$max_wait_s" ]; then
      timed_out=1
      break
    fi

    sleep 1
  done

  if [[ "$ui_backend" != "text" ]]; then
    if [ "$timed_out" -eq 1 ]; then
      ui_msg "ZIP Download" "Zip download completed. Flush wait timed out after ${max_wait_s}s (Dirty: ${dirty_kb} KB, Writeback: ${writeback_kb} KB). Continuing."
    else
      ui_msg "ZIP Download" "Zip download and ready."
    fi
  else
    printf '\n'
    if [ "$timed_out" -eq 1 ]; then
      echo "Zip download completed. Flush wait timed out after ${max_wait_s}s (Dirty: ${dirty_kb} KB, Writeback: ${writeback_kb} KB). Continuing."
    else
      echo "Zip download and ready."
    fi
  fi
}

download_file "$JSON_URL" "$TMP_JSON"

if ! command -v php >/dev/null 2>&1; then
  echo "Error: php is required to parse release metadata."
  exit 1
fi

RELEASES_FILE="$(mktemp)"
# The PHP parser is intentionally single-quoted so the shell does not expand PHP variables.
# shellcheck disable=SC2016
php -r '
  $json = json_decode(file_get_contents($argv[1]), true);
  if (!is_array($json)) {
    fwrite(STDERR, "Invalid JSON\\n");
    exit(1);
  }
  $emit = function(array $entry) use ($argv) {
    $name = $entry["name"] ?? "";
    $url = $entry["url"] ?? "";
    $date = $entry["release_date"] ?? "";

    if (!preg_match("/\\b(\\d+\\.\\d+(?:\\.\\d+)*)\\b/", $name, $m)) return;
    $version = $m[1];
    if (version_compare($version, $argv[2], "<")) return;
    if ($url === "" || stripos($url, ".zip") === false) return;

    echo $name . "|" . $version . "|" . $date . "|" . $url . PHP_EOL;
  };

  foreach (($json["os_list"] ?? []) as $entry) {
    if (!is_array($entry)) continue;
    $emit($entry);

    foreach (($entry["subitems"] ?? []) as $subitem) {
      if (!is_array($subitem)) continue;
      $emit($subitem);
    }
  }
' "$TMP_JSON" "$MIN_VERSION" > "$RELEASES_FILE"

mapfile -t RELEASES < "$RELEASES_FILE"
rm -f "$RELEASES_FILE"

if [ ${#RELEASES[@]} -eq 0 ]; then
  echo "No Unraid ${MIN_VERSION}+ zip releases were found."
  exit 1
fi

selected=""
if [[ "$LATEST_ONLY" -eq 1 ]]; then
  selected="$(printf '%s\n' "${RELEASES[@]}" | sort -t'|' -k2,2V | tail -n1)"
elif [[ "$ui_backend" != "text" ]]; then
  menu_args=()
  for i in "${!RELEASES[@]}"; do
    IFS='|' read -r name _version _date _url <<< "${RELEASES[$i]}"
    if [[ -n "$_date" ]]; then
      menu_args+=("$i" "$name ($_date)")
    else
      menu_args+=("$i" "$name")
    fi
  done

  choice="$(ui_menu_select "Select Release" "Select a release to download" "${menu_args[@]}")" || {
    echo "No download selected."
    exit 0
  }
  selected="${RELEASES[$choice]}"
else
  echo
  echo "Available Unraid ${MIN_VERSION}+ zip releases:"
  echo
  for i in "${!RELEASES[@]}"; do
    IFS='|' read -r name _version _date url <<< "${RELEASES[$i]}"
    printf '%2d) %s' "$((i + 1))" "$name"
    if [ -n "$_date" ]; then
      printf ' (%s)' "$_date"
    fi
    printf '\n'
  done
  echo

  while true; do
    choice="$(ui_prompt "Select Release" "Select a release number to download (0 or Enter to exit)")"
    if [[ -z "$choice" || "$choice" == "0" ]]; then
      echo "No download selected."
      exit 0
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#RELEASES[@]} ]; then
      break
    fi
    echo "Invalid selection. Enter a number between 1 and ${#RELEASES[@]}, or 0/Enter to exit."
  done

  selected="${RELEASES[$((choice - 1))]}"
fi
IFS='|' read -r selected_name _selected_version _selected_date selected_url <<< "$selected"

if [[ -z "$selected_url" ]]; then
  echo "No valid release URL selected."
  exit 1
fi

validate_release_zip_url "$selected_url"

filename="$(release_zip_filename "$selected_url")"
dest_file="${ZIP_DIR}/${filename}"

if [ -e "$dest_file" ]; then
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "Latest release already present: ${dest_file}"
    exit 0
  fi
  if ! ui_confirm "Overwrite File" "${filename} already exists. Overwrite?" "n"; then
    echo "Download canceled."
    exit 0
  fi
fi

echo "Downloading ${selected_name}..."
download_release_zip "$selected_url" "$dest_file"

flush_writeback_progress
echo "Saved to: ${dest_file}"
