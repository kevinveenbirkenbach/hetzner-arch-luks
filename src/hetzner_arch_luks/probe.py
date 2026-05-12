"""Client-side reachability probes that need no SSH credentials."""
from __future__ import annotations

import shutil
import socket
import subprocess


def _have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def _ssh_banner(host: str, port: int = 22, timeout: float = 3) -> str:
    """Read the first line the SSH server emits on connect.

    Distinguishes Hetzner rescue (Debian OpenSSH banner) from installed Arch
    (Arch OpenSSH banner) from Dropbear (Dropbear banner).
    """
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(2)
            data = s.recv(256)
            return data.decode("utf-8", errors="replace").splitlines()[0] if data else ""
    except (OSError, socket.timeout, UnicodeDecodeError):
        return ""


def status(host: str) -> int:
    """Print a reachability report for `host`. Returns 0 always."""
    print(f"==> ping (ICMP) {host}")
    try:
        subprocess.run(["ping", "-c", "2", "-W", "2", host], check=False)
    except FileNotFoundError:
        print("(ping not available)")

    print()
    print(f"==> ports 22, 222 on {host}")
    if _have("nmap"):
        subprocess.run(["nmap", "-Pn", "-p", "22,222", host], check=False)
    else:
        print("(nmap not installed; falling back to TCP probes)")
        for port in (22, 222):
            ok = False
            try:
                with socket.create_connection((host, port), timeout=3):
                    ok = True
            except (OSError, socket.timeout):
                pass
            print(f"  {port}: {'reachable' if ok else 'not reachable (filtered/closed/timeout)'}")

    print()
    print(f"==> SSH banner on {host}:22")
    banner = _ssh_banner(host, 22)
    print(banner if banner else "(no banner)")
    return 0
