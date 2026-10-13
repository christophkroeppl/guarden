#!/usr/bin/env python3
"""The pinned hop, measured on the machine, for `t130-alias.sh`.

usage: t130-hop.py <port> <network> <image> <report>

Run as the unprivileged `ubuntu` user, which owns the subuid range and is the
only account that can run a rootless pasta container. The helper binds
127.0.0.1:<port>, starts one real container as the client — dialling the
gateway pinned in `<network>` (podman's `pasta:` value, comma-joined) at the
host's loopback — and, **while both ends are up**, reads the kernel's own
socket table. A suite cannot take that sample itself: the connection exists
only for the life of the container client, the harness runs one command per
shell invocation, and a listener backgrounded out of a suite is a job nothing
waits for. So both ends of the connection live here.

It writes what it measured into <report> as `key=value` lines:

    peer=127.0.0.1           the accepted socket's peer, read at accept time
    received=hop             the payload the container sent
    ss_local=127.0.0.1:<port>
    ss_peer=127.0.0.1:<n>
    uid=1000                 the socket's owner: `ss -e`'s `uid:` field, or
                             /proc/net/tcp's when `ss` does not print one
    ss=<the raw ss line, verbatim>
    proc_local=127.0.0.1     /proc/net/tcp's own view, decoded
    proc_remote=127.0.0.1
    proc_uid=1000
    route=<each host route, one line per route>
    client=<the container client's exit code>

This is a helper and not a fixture: `podman`, `ss`, `ip` and the kernel's
tables are the machine's own, and nothing here stands in for any of them. It
exits 0 with the report written, or 1 with one `error:` line naming every fact
it could not measure.
"""

from __future__ import annotations

import socket
import subprocess
import sys
from pathlib import Path

# How long the client keeps the connection open for the sample below. The
# client's stdin is a pipe whose write end is a `sleep`, so the connection is
# established when the sample is taken and closes when this side does; the
# sample itself takes microseconds, and the hold only has to outlast it.
HOLD = 3


def _run(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


def _ss(port: int) -> tuple[str, str, str]:
    """The established socket on `port`, as `ss` reports it: line, local, peer.

    `-e` is load-bearing: it is what makes `ss` print the `uid:` field, and the
    uid is one of the facts this helper exists to measure. The kernel's own
    table is read as well, below, so the fact survives an `ss` that does not.

    The columns are found rather than counted: `ss` prints a `State` column with
    no state filter and omits it when one is given, so the field whose address
    ends in `:<port>` is the local end wherever the columns happen to start, and
    the peer is the field beside it.
    """
    result = _run(["ss", "-tnpe", "state", "established"])
    for line in result.stdout.splitlines():
        fields = line.split()
        for index, field in enumerate(fields):
            if field.endswith(f":{port}") and index + 1 < len(fields):
                return line, field, fields[index + 1]
    return "", "", ""


def _proc(port: int) -> tuple[str, str, str]:
    """The same socket out of /proc/net/tcp: local, remote, uid — all decoded.

    The addresses are little-endian hex in the kernel's table and the state is
    `01` for ESTABLISHED; decoding both here is what keeps the suite's
    assertions on dotted quads rather than on the kernel's spelling.
    """
    try:
        rows = Path("/proc/net/tcp").read_text().splitlines()
    except OSError:
        return "", "", ""
    for row in rows[1:]:
        fields = row.split()
        if len(fields) < 8 or fields[3] != "01":
            continue
        if not fields[1].endswith(f":{port:04X}"):
            continue
        local = socket.inet_ntoa(bytes.fromhex(fields[1].split(":")[0])[::-1])
        remote = socket.inet_ntoa(bytes.fromhex(fields[2].split(":")[0])[::-1])
        return local, remote, fields[7]
    return "", "", ""


def _uid_of(line: str, port: int) -> str:
    for field in line.split():
        if field.startswith("uid:"):
            return field.split(":", 1)[1]
    return _proc(port)[2]


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        sys.stderr.write(f"usage: {argv[0]} <port> <network> <image> <report>\n")
        return 2
    try:
        port = int(argv[1])
    except ValueError:
        sys.stderr.write(f"error: {argv[1]!r} is not a port\n")
        return 2
    network, image, report = argv[2], argv[3], Path(argv[4])
    pieces = network.removeprefix("pasta:").split(",")
    if "-g" not in pieces or pieces.index("-g") + 1 >= len(pieces):
        sys.stderr.write(f"error: {network} pins no gateway, so there is nothing to dial\n")
        return 1
    gateway = pieces[pieces.index("-g") + 1]

    facts: dict[str, str] = {}
    problems: list[str] = []
    route_lines: list[str] = []

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.bind(("127.0.0.1", port))
        listener.listen(1)
    except OSError as exc:
        sys.stderr.write(f"error: 127.0.0.1:{port} could not be bound: {exc}\n")
        return 1
    listener.settimeout(30)

    try:
        client = subprocess.Popen(
            ["podman", "run", "--rm", "--log-level=error", "--network", network,
             image, "/bin/busybox", "sh", "-c",
             f"{{ echo hop; sleep {HOLD}; }} | nc -w 8 {gateway} {port}"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except OSError as exc:
        sys.stderr.write(f"error: the container client could not be started: {exc}\n")
        return 1

    try:
        connection, peer = listener.accept()
    except OSError as exc:
        client.kill()
        _, client_err = client.communicate()
        reported = client_err.strip().splitlines()
        detail = reported[0] if reported else str(exc)
        problems.append(f"no connection from the container arrived at 127.0.0.1:{port}: {detail}")
    else:
        facts["peer"] = peer[0]
        connection.settimeout(10)

        # While both ends are up: the socket table and the host's route table.
        # The route sample belongs to this moment — a route that only appeared
        # while the container ran would be gone by the time a suite looked.
        ss_line, ss_local, ss_peer = _ss(port)
        if not ss_line:
            problems.append(f"ss names no established connection on 127.0.0.1:{port}")
        else:
            facts["ss_local"] = ss_local
            facts["ss_peer"] = ss_peer
            facts["ss"] = ss_line
        uid = _uid_of(ss_line, port)
        if not uid:
            problems.append("the connection has no uid in ss or /proc/net/tcp")
        else:
            facts["uid"] = uid
        proc_local, proc_remote, proc_uid = _proc(port)
        if not proc_local:
            problems.append("the kernel's table names no established connection")
        else:
            facts["proc_local"] = proc_local
            facts["proc_remote"] = proc_remote
            facts["proc_uid"] = proc_uid
        route = _run(["ip", "-4", "route", "show"])
        if route.returncode != 0:
            problems.append(f"the host's route table could not be read: {route.stderr.strip()}")
        route_lines = [f"route={line}" for line in route.stdout.splitlines() if line.strip()]

        payload = b""
        while b"\n" not in payload:
            try:
                chunk = connection.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            payload += chunk
        connection.close()
        facts["received"] = payload.decode("utf-8", "replace").strip()
        if not facts["received"]:
            problems.append("the container's payload did not arrive")

        try:
            client.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            client.kill()
            client.communicate()
            problems.append("the container client did not exit")
        facts["client"] = str(client.returncode)

    order = ["peer", "received", "ss_local", "ss_peer", "uid", "ss",
             "proc_local", "proc_remote", "proc_uid", "client"]
    lines = [f"{key}={facts[key]}" for key in order if key in facts] + route_lines
    report.write_text("\n".join(lines) + ("\n" if lines else ""))
    if problems:
        sys.stderr.write("error: " + "; ".join(problems) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
