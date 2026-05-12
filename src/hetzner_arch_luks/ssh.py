"""SSH helpers using OpenSSH ControlMaster for connection reuse.

The `SshSession` context manager opens a single SSH connection on enter
(interactive: password / host key accept happens here once) and then runs
follow-up commands over the same multiplexed channel without re-auth.

We deliberately wrap the OpenSSH client rather than using a library like
paramiko so the user's existing config (~/.ssh/config, agent, key files,
known_hosts) just works.
"""
from __future__ import annotations

import os
import shutil
import socket
import subprocess
import tempfile
import time


def remove_stale_known_hosts(host: str) -> None:
    """Drop any cached host key for `host`.

    Each Hetzner rescue activation generates a fresh host key, so a stale
    entry would otherwise block the connection with a MITM warning.
    """
    known = os.path.expanduser("~/.ssh/known_hosts")
    if not os.path.exists(known):
        return
    subprocess.run(
        ["ssh-keygen", "-f", known, "-R", host],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def tcp_reachable(host: str, port: int, timeout: float = 3) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (OSError, socket.timeout):
        return False


def wait_for_port(host: str, port: int = 22, timeout: int = 300, interval: int = 2) -> bool:
    """Block until host:port accepts TCP or `timeout` elapses."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if tcp_reachable(host, port, timeout=2):
            return True
        time.sleep(interval)
    return False


class SshSession:
    """Persistent SSH connection to one host via OpenSSH ControlMaster.

    Use as a context manager. The master is opened by running a no-op remote
    command during __enter__; this is where interactive prompts (password,
    host key acceptance) happen. Subsequent `run()` calls reuse the cached
    connection.

    Example:
        with SshSession("rescue.example.com") as ssh:
            ssh.run("uname -a")
            ssh.run("cat", input_=b"hello")
            ssh.run("/bin/bash", tty=True)  # interactive shell
    """

    def __init__(self, host: str, user: str = "root"):
        self.host = host
        self.user = user
        self._tmpdir: str | None = None
        self._sock: str | None = None

    # ---- context management -------------------------------------------------

    def __enter__(self) -> "SshSession":
        self._tmpdir = tempfile.mkdtemp(prefix="hal-ssh-")
        self._sock = os.path.join(self._tmpdir, "ctl")
        remove_stale_known_hosts(self.host)
        # Open the master with a quick no-op. Auth (and any TTY prompts) happen
        # right here. After this returns, the socket at self._sock is live and
        # follow-up ssh invocations reusing it skip auth entirely.
        cmd = [
            "ssh",
            "-o", "ControlMaster=auto",
            "-o", f"ControlPath={self._sock}",
            "-o", "ControlPersist=10m",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            f"{self.user}@{self.host}",
            "true",
        ]
        subprocess.run(cmd, check=True)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._sock and os.path.exists(self._sock):
            subprocess.run(
                [
                    "ssh", "-o", f"ControlPath={self._sock}",
                    "-O", "exit", f"{self.user}@{self.host}",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        if self._tmpdir and os.path.isdir(self._tmpdir):
            shutil.rmtree(self._tmpdir, ignore_errors=True)

    # ---- remote execution ---------------------------------------------------

    def run(
        self,
        remote_cmd: str,
        *,
        tty: bool = False,
        input_: bytes | None = None,
        check: bool = True,
        capture: bool = False,
    ) -> subprocess.CompletedProcess:
        """Run `remote_cmd` on the remote host over the multiplexed channel.

        remote_cmd : Shell command(s) as a single string. Newlines OK — the
                     remote shell parses them as multiple statements.
        tty        : Allocate a remote pseudo-tty (needed for interactive
                     tools like `bash` or things using /dev/tty).
        input_     : Bytes to feed to the remote command's stdin. Mutually
                     exclusive with tty (no terminal if stdin is a pipe).
        check      : Raise CalledProcessError on non-zero exit.
        capture    : Capture stdout/stderr in the returned CompletedProcess
                     instead of inheriting the parent's.
        """
        if tty and input_ is not None:
            raise ValueError("tty=True is incompatible with feeding stdin via input_")
        cmd = ["ssh", "-o", f"ControlPath={self._sock}"]
        if tty:
            cmd += ["-t"]
        cmd += [f"{self.user}@{self.host}", remote_cmd]
        kwargs: dict = {"check": check}
        if input_ is not None:
            kwargs["input"] = input_
        if capture:
            kwargs["capture_output"] = True
        return subprocess.run(cmd, **kwargs)
