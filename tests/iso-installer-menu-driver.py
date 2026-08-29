#!/usr/bin/env python3
"""Drive the real ISO installer text menu through a QEMU serial socket."""

from __future__ import annotations

import argparse
import os
import re
import select
import socket
import sys
import time
from pathlib import Path


ANSI_ESCAPE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--transcript", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=1200)
    return parser.parse_args()


def connect(path: Path, deadline: float) -> socket.socket:
    while time.monotonic() < deadline:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.connect(os.fspath(path))
            client.setblocking(False)
            return client
        except (FileNotFoundError, ConnectionRefusedError):
            client.close()
            time.sleep(0.25)
    raise TimeoutError(f"serial socket did not become ready: {path}")


def clean_output(data: str) -> str:
    return ANSI_ESCAPE.sub("", data).replace("\r", "")


def main() -> int:
    args = parse_args()
    deadline = time.monotonic() + args.timeout
    steps = [
        ("Press Enter to continue...", "\n"),
        ("Enter option key:", "C\n"),
        ("How many boot devices should be created?", "2\n"),
        ("Enter target disk (example: nvme1n1):", "nvme0n1\n"),
        ("Enter target disk (example: nvme1n1):", "nvme1n1\n"),
        ("Enter pool name", "\n"),
        ("Type YES to continue:", "YES\n"),
        ("View full operation log now?", "\n"),
        ("Enter option key:", None),
    ]

    args.transcript.parent.mkdir(parents=True, exist_ok=True)
    client = connect(args.socket, deadline)
    observed = ""
    search_at = 0

    with client, args.transcript.open("wb") as transcript:
        for pattern, response in steps:
            while pattern not in observed[search_at:]:
                if time.monotonic() >= deadline:
                    tail = observed[-4000:]
                    print(f"Timed out waiting for installer prompt: {pattern}\n{tail}", file=sys.stderr)
                    return 1
                readable, _, _ = select.select([client], [], [], 1.0)
                if not readable:
                    continue
                chunk = client.recv(65536)
                if not chunk:
                    print(f"Serial socket closed while waiting for: {pattern}", file=sys.stderr)
                    return 1
                transcript.write(chunk)
                transcript.flush()
                observed += clean_output(chunk.decode("utf-8", errors="replace"))

            pattern_end = observed.index(pattern, search_at) + len(pattern)
            # Keep matching sequential. This prevents the final menu assertion from
            # matching the first menu prompt again.
            search_at = pattern_end
            print(f"Matched installer prompt: {pattern}")
            if response is not None:
                client.sendall(response.encode())

    print("Real ISO installer menu flow completed successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
