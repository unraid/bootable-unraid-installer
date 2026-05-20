#!/usr/bin/env python3
"""Update the pinned Unraid OS release used for seeded installer images."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_METADATA_URL = "https://releases.unraid.net/usb-creator"
DEFAULT_MIN_VERSION = "7.3.0"
DEFAULT_LOCK_PATH = Path("build/unraid-release-lock.json")
DEFAULT_CHANNEL = "stable"
USER_AGENT = "unraid-installer-release-lock"


def version_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def find_version(name: str) -> str | None:
    match = re.search(r"\b(\d+\.\d+(?:\.\d+)*)\b", name)
    if not match:
        return None
    return match.group(1)


def validate_release_url(url: str, version: str, channel: str) -> tuple[str, str]:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or parsed.netloc != "releases.unraid.net":
        raise ValueError(f"unsupported release URL host or scheme: {url}")
    path_parts = [part for part in parsed.path.split("/") if part]
    if len(path_parts) < 5 or path_parts[0] != "dl":
        raise ValueError(f"unsupported release URL path: {url}")
    if path_parts[1] != channel:
        raise ValueError(f"release URL channel is {path_parts[1]}, expected {channel}: {url}")

    digest = path_parts[-2]
    filename = path_parts[-1]
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"release URL does not contain a SHA256 path segment: {url}")
    expected_filename = f"unRAIDServer-{version}-x86_64.zip"
    if filename != expected_filename:
        raise ValueError(f"expected {expected_filename}, got {filename}")
    return filename, digest


def release_entries(metadata: dict) -> list[dict]:
    entries: list[dict] = []
    stack = list(metadata.get("os_list") or [])
    while stack:
        entry = stack.pop(0)
        if not isinstance(entry, dict):
            continue
        entries.append(entry)
        for subitem in entry.get("subitems") or []:
            if isinstance(subitem, dict):
                stack.append(subitem)
    return entries


def sha256_url(url: str) -> str:
    digest = hashlib.sha256()
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=600) as response:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def latest_release(
    metadata: dict,
    metadata_url: str,
    min_version: str,
    channel: str,
    verify_download: bool,
) -> dict:
    candidates = []
    minimum = version_tuple(min_version)
    for entry in release_entries(metadata):
        name = str(entry.get("name") or "")
        url = str(entry.get("url") or "")
        version = find_version(name)
        if not version or version_tuple(version) < minimum or ".zip" not in url:
            continue
        try:
            filename, sha256 = validate_release_url(url, version, channel)
        except ValueError:
            continue
        candidates.append((version_tuple(version), entry, version, filename, sha256))

    if not candidates:
        raise RuntimeError(f"no {channel} Unraid ZIP releases found at or above {min_version}")

    _version_key, entry, version, filename, url_sha256 = max(candidates, key=lambda item: item[0])
    sha256 = sha256_url(entry["url"]) if verify_download else url_sha256
    return {
        "schema": 1,
        "source": {
            "metadata_url": metadata_url,
            "minimum_version": min_version,
            "channel": channel,
        },
        "channel": channel,
        "name": entry.get("name") or f"Unraid {version}",
        "version": version,
        "release_date": entry.get("release_date") or "",
        "website": entry.get("website") or "",
        "url": entry.get("url"),
        "filename": filename,
        "sha256": sha256,
        "url_sha256": url_sha256,
        "image_download_size": entry.get("image_download_size"),
        "extract_size": entry.get("extract_size"),
    }


def load_json_url(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def comparable(lock: dict) -> dict:
    return {key: value for key, value in lock.items() if key != "updated_at"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata-url", default=DEFAULT_METADATA_URL)
    parser.add_argument("--min-version", default=DEFAULT_MIN_VERSION)
    parser.add_argument("--channel", default=DEFAULT_CHANNEL, choices=("stable",))
    parser.add_argument("--lock-path", type=Path, default=DEFAULT_LOCK_PATH)
    parser.add_argument(
        "--verify-download",
        action="store_true",
        help="Download the selected ZIP and pin its actual SHA256 instead of trusting the URL digest.",
    )
    args = parser.parse_args()

    metadata = load_json_url(args.metadata_url)
    lock = latest_release(
        metadata,
        args.metadata_url,
        args.min_version,
        args.channel,
        args.verify_download,
    )

    existing = None
    if args.lock_path.exists():
        existing = json.loads(args.lock_path.read_text())
        if not args.verify_download and existing.get("url") == lock.get("url"):
            lock["sha256"] = existing.get("sha256") or lock["sha256"]
        if comparable(existing) == comparable(lock):
            print(f"Unraid release lock already current: {lock['version']}")
            return 0

    lock["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    args.lock_path.parent.mkdir(parents=True, exist_ok=True)
    args.lock_path.write_text(json.dumps(lock, indent=2, sort_keys=False) + "\n")
    print(f"Updated {args.lock_path} to Unraid {lock['version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
