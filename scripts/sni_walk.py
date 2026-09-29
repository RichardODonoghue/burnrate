#!/usr/bin/env python3
"""Print the D-Bus object tree of each given bus name (session bus).

    python3 scripts/sni_walk.py :1.2 :1.5

Used by the tray smoke to discover where the app actually exports its
StatusNotifierItem / AppIndicator and DBusMenu objects: on Linux Tauri goes
through libayatana-appindicator, so the object path is not the
`/StatusNotifierItem` the old hand-rolled tray used.
"""
from __future__ import annotations

import re
import subprocess
import sys

INTERFACES_OF_INTEREST = ("StatusNotifier", "dbusmenu", "NotificationItem", "Introspectable")


def call(dest: str, path: str, method: str) -> str:
    try:
        result = subprocess.run(
            [
                "gdbus", "call", "--session", "--dest", dest,
                "--object-path", path, "--method", method,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return ""
    return result.stdout if result.returncode == 0 else ""


def walk(dest: str, path: str, depth: int = 0, max_depth: int = 5) -> None:
    xml = call(dest, path, "org.freedesktop.DBus.Introspectable.Introspect")
    if not xml:
        return
    interfaces = [
        name
        for name in re.findall(r'interface name="([^"]+)"', xml)
        if "freedesktop.DBus" not in name
    ]
    print(f"{path}  {interfaces}")
    if depth >= max_depth:
        return
    prefix = path.rstrip("/")
    for child in re.findall(r'<node name="([^"]+)"\s*/>', xml):
        walk(dest, f"{prefix}/{child}", depth + 1, max_depth)


def main() -> None:
    for name in sys.argv[1:]:
        print(f"=== {name} ===")
        walk(name, "/")


if __name__ == "__main__":
    main()
