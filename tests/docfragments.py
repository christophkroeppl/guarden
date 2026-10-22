#!/usr/bin/env python3
"""Orphaned sentences in a document: a paragraph whose first half was rewritten
and whose second half was left behind.

usage: docfragments.py <document> [<document>...]

**A sentence with no subject.** The defect is a document edit that replaced a
paragraph's opening and left its tail in place, so the paragraph reads

    **A claim.**<newline>
    these two with a substitution and validated nothing, which meant ...

The second line has no subject and no verb, because the words that made it a
sentence were in the part that was rewritten. The reader gets a fragment and
nothing says so — and the document it sits in is the one the suites check the
code against, so a fragment there is a claim about the code that nobody can
read.

**The detector is structural, not a phrase list.** A phrase list names the
fragments someone has already found, and the next fragment is a new phrase. So
this asks a question about the SHAPE of the document instead: does a sentence
begin with a lowercase word where the previous line ended a complete sentence?

That is the shape a rewrite leaves behind, and it is narrow enough to be
precise:

  * the previous line ends a COMPLETE bold sentence — `.**` — so the fragment
    follows a sentence that is finished, not one that is still going;
  * the next line is prose, not a list item, a table row, a heading or a quote,
    so it is a continuation of the paragraph rather than a new block;
  * the next line's first word is lowercase, so it cannot be the start of a
    sentence — a subject noun would be capitalised, and a pronoun at the start
    of a sentence is `It`/`They`/`This`, never `these`/`this`/`that` mid-paragraph.

A blank line between the two ends the paragraph, and a fragment on the far side
of a blank line is a paragraph of its own — so the detector requires them to be
adjacent. A fenced code block is not prose: a sample's contents are not
sentences, and the fence markers themselves are not either.

**Measured on this repository's own documents.** Before the repair this found
four fragments in `docs/spec.md` and none in `docs/sysadmin.md`,
`CONTEXT.md`, `AGENTS.md`, `docs/PRD.md` or `SECURITY.md`. All four were
orphaned by the same commit (67740995, the ADR folding), each by the same
mechanism: the paragraph's opening was rewritten and its tail left behind. The
detector finds those four and nothing else, and it finds none in the pre-fold
revision of the same document — so it is measuring the defect, not the file's
prose style.

Run by tests/t481-doc-fragments.sh.
"""

from __future__ import annotations

import re
import sys

# A line that ends a COMPLETE bold sentence: `.**` at the end, optionally
# followed by whitespace.
COMPLETE_BOLD = re.compile(r"\.\*\*\s*$")

# The first word of a continuation line.
FIRST_WORD = re.compile(r"[A-Za-z][A-Za-z'’-]*")

# A line that starts a block rather than continuing a paragraph.
BLOCK_START = ("-", "*", ">", "|", "#", "=", "+")


def fenced_lines(lines: list[str]) -> list[bool]:
    """Which lines are inside a fenced code block.

    The fence markers themselves are not prose either, so they are marked as
    fenced as well.
    """
    inside = False
    marks: list[bool] = []
    for line in lines:
        if line.lstrip().startswith("```"):
            inside = not inside
            marks.append(True)
            continue
        marks.append(inside)
    return marks


def fragments(lines: list[str]) -> list[tuple[int, str]]:
    """The orphaned sentences, as (line number, the fragment's text)."""
    marks = fenced_lines(lines)
    found: list[tuple[int, str]] = []
    for i in range(len(lines) - 1):
        if marks[i] or marks[i + 1]:
            continue
        previous = lines[i].rstrip()
        if not COMPLETE_BOLD.search(previous):
            continue
        following = lines[i + 1].strip()
        if not following or following.startswith(BLOCK_START):
            continue
        word = FIRST_WORD.match(following)
        if not word or word.group(0)[0].isupper():
            continue
        found.append((i + 2, following))
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: docfragments.py DOCUMENT...\n")
        return 2
    failed = False
    for path in argv[1:]:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError as exc:
            sys.stderr.write(f"error: cannot read {path}: {exc}\n")
            failed = True
            continue
        for number, fragment in fragments(text.split("\n")):
            failed = True
            print(
                f"error: {path}:{number} is a sentence with no subject — it follows a "
                f"completed sentence and begins with a lowercase word: {fragment[:70]}",
                file=sys.stderr,
            )
    if failed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
