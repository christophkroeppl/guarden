#!/usr/bin/env python3
"""Drive a program through a pty and type the answers into it.

The guided creator refuses a non-terminal — that refusal is one of the
design's three constraints, because a secret read from a pipe was already in
the clear where the pipe produced it. So a suite that drives the creator's
prompts has to give it a TTY, and `expect` is not on the box.

**This is a stdlib pty driver, and not `script -qc`.** `script` is on some
distributions and not on others, and its transcript format differs between
util-linux versions. `pty` is in the standard library on every one of them,
and the driver below says exactly what it did: the answers it typed, what the
program printed, and the exit code it returned.

Usage:

    tests/pty-drive.py <answers-file> -- <command...>

The answers file holds one answer per line, and an empty line is an answer
too — it is how a question with a default is answered with the default. The
program is run with a pty on stdin AND stdout, so `isatty()` is true on both
sides, and the answers are written as the program asks for them.

The exit code is the program's own. The transcript goes to stdout, so a
suite that fails can print it.
"""

from __future__ import annotations

import os
import pty
import select
import subprocess
import sys

# How long to wait for the program to produce output before deciding it is
# done. The creator answers a prompt as fast as it is typed, so this is only
# the tail of the last answer.
IDLE_SECONDS = 30.0
# How long to wait between polls.
POLL_SECONDS = 0.05


def main(argv: list[str]) -> int:
    if "--" not in argv:
        sys.stderr.write("usage: pty-drive.py <answers-file> -- <command...>\n")
        return 2
    split = argv.index("--")
    answers_path = argv[0]
    command = argv[split + 1 :]
    if not command:
        sys.stderr.write("usage: pty-drive.py <answers-file> -- <command...>\n")
        return 2

    with open(answers_path, encoding="utf-8") as handle:
        answers = [line.rstrip("\n") for line in handle]

    master, slave = pty.openpty()
    try:
        process = subprocess.Popen(
            command,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
        )
    finally:
        os.close(slave)

    transcript: list[str] = []
    pending = list(answers)
    # The quiet period before the next answer is typed. A prompt arrives and
    # the program waits, so the pty goes quiet — and the quiet IS the prompt,
    # so the wait is short enough to feel immediate and long enough not to
    # split a line the program is still writing.
    quiet = 0.25
    waited = 0.0
    while True:
        if process.poll() is not None:
            break
        ready, _, _ = select.select([master], [], [], POLL_SECONDS)
        if ready:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                break
            if not chunk:
                break
            transcript.append(chunk.decode("utf-8", "replace"))
            waited = 0.0
            continue
        # Nothing came out. If the program is waiting for an answer, give it
        # one — and if there is none left, wait for the program to finish.
        waited += POLL_SECONDS
        if waited < quiet:
            continue
        if pending:
            os.write(master, (pending.pop(0) + "\n").encode("utf-8"))
            waited = 0.0
            continue
        if waited > IDLE_SECONDS:
            break

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
    try:
        os.close(master)
    except OSError:
        pass

    sys.stdout.write("".join(transcript))
    sys.stdout.flush()
    if pending:
        sys.stderr.write(
            f"pty-drive: {len(pending)} answers were never typed\n"
        )
    return process.returncode if process.returncode is not None else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
