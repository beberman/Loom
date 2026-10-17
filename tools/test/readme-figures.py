#!/usr/bin/env python3
"""Write, or check, the figures block of README.md.

    tools/test/readme-figures.py            rewrite the block
    tools/test/readme-figures.py --check    rewrite nothing; compare

REQ-0079 R4 and PLAN-0061 step 13, under the owner's decision D5 (a). The block sits
between the lines `<!-- figures:begin -->` and `<!-- figures:end -->`. Its first line
names the commit and the date the figures were taken at. Every other line is read from
the tree, and none is typed.

The figures come from two places.

    tools/synoptik.sh 'status | structure | help'
        the test count, from the `tests` line of `status`; the twelve systems, from the
        `systems` section of `structure`; the console commands, from the `help` table
    sbcl --script tools/test/surface.lisp
        the analyzers and the file types they claim, the entity and relationship types,
        the synoptik-serve operations with their tiers (each is a REST route at
        /v1/<name>), and the MCP tool names

A system is listed when `structure` lists it and src/ holds a .asd file of that name.
The .asd file is what makes it one of the twelve and not one of the other packages
`structure` names (the test packages, the scripts under tools/test).

Not included, because each changes with nearly every commit and the block would then be
stale after the first one: the counts of files, entities, relationships and documents
that `status` prints; the per-system entity counts and the edges between systems that
`structure` prints; and the `built from` line, which carries the commit. The test count
is included because R4 names it, and it moves only when a test is added or removed.
The edges are left out for a second reason: they are calls the index resolved, some by
spelling alone (CLAUDE.md, on a package it cannot place), and a table of them beside the
declared layering would show the index's mistakes as architecture.

With --check the figures are regenerated in memory and compared with the block. The
first line of the block is not compared: once the README is committed, HEAD has moved
on, so the commit it names can never equal HEAD (PLAN-0061 finding 14). D5 (a): the
check fails when any figure differs from what regenerating would write, and CONTRIBUTING
makes regenerating part of a release and not of every pull request.

The figures are those of the working tree, and the first line says when that tree had
uncommitted changes other than README.md. README.md is left out of that test because
writing the block changes it, and a second run must write the same bytes as the first.
The date is the commit's date and not today's, for the same reason.

Exit status: 0 when the block was written or is current; 1 when --check finds a figure
that differs, naming the first one; 2 when README.md has no usable marker pair; 3 when a
figure could not be measured (the service's script or sbcl is missing, or one of them
failed) or an argument is not understood. A figure that cannot be measured is one
sentence on stderr and never a blank in the block.
"""

import glob
import os
import re
import subprocess
import sys

BEGIN = "<!-- figures:begin -->"
END = "<!-- figures:end -->"
FENCE = "```"
WIDTH = 78


class FigureError(Exception):
    """A figure that could not be measured; the message is the sentence to print."""


def checkout_dir():
    """The repository this script lives in, found from its own location."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def command_output(argv, root, measured):
    """The standard output of ARGV run in ROOT, or a FigureError saying that MEASURED
    was not measured. The sentence names the program by its file name, never its path."""
    try:
        done = subprocess.run(argv, cwd=root, capture_output=True, text=True,
                              encoding="utf-8", timeout=900)
    except FileNotFoundError:
        raise FigureError("%s is not on PATH. Not measured: %s." % (argv[0], measured))
    except subprocess.TimeoutExpired:
        raise FigureError("%s did not finish in 900 seconds. Not measured: %s."
                          % (os.path.basename(argv[0]), measured))
    if done.returncode != 0:
        tail = (done.stderr.strip().splitlines() or ["no message"])[-1]
        raise FigureError("%s exited %d (%s). Not measured: %s."
                          % (os.path.basename(argv[0]), done.returncode, tail, measured))
    return done.stdout


def wrapped_names(names):
    """NAMES one space apart, indented two spaces, wrapped before column 78. The same
    rule tools/test/surface.lisp applies to its lists."""
    lines, current = [], ""
    for name in names:
        if current and len(current) + 1 + len(name) > WIDTH:
            lines.append(current)
            current = ""
        current = current + " " + name if current else "  " + name
    if current:
        lines.append(current)
    return lines


def tests_text(status_text):
    """What the `tests` line of `status` says, as printed, after the colon."""
    found = re.search(r"^\s+tests\s*:\s*(.+?)\s*$", status_text, re.M)
    if not found:
        raise FigureError("`status` printed no tests line. Not measured: the test count.")
    return found.group(1)


def structure_systems(structure_text, root):
    """The systems `structure` lists that src/ holds a .asd file for, lower case, sorted."""
    listed = set(re.findall(r"^  ([A-Z][A-Z0-9-]*)\s+\d+ entities", structure_text, re.M))
    declared = [os.path.basename(path)[:-len(".asd")].upper()
                for path in glob.glob(os.path.join(root, "src", "*", "*.asd"))]
    missing = sorted(name for name in declared if name not in listed)
    if not declared or missing:
        raise FigureError("`structure` does not list %s. Not measured: the systems."
                          % (", ".join(missing) if missing else "any system with a .asd file"))
    return sorted(name.lower() for name in declared)


def console_commands(help_text):
    """The command names in the `help` table, sorted. A command starts a line indented
    two spaces; the lines that continue its description start in column 0."""
    start = help_text.find("Synoptik console. Commands:")
    if start < 0:
        raise FigureError("`help` printed no command table. Not measured: the console commands.")
    end = help_text.find("\nsynoptik>", start)
    table = help_text[start:end if end > 0 else len(help_text)]
    names = re.findall(r"^  ([a-z][a-z-]*)(?= |$)", table, re.M)
    if not names:
        raise FigureError("`help` listed no commands. Not measured: the console commands.")
    return sorted(set(names))


def figure_lines(root):
    """Every line of the block after its first, in order."""
    console = command_output([os.path.join(root, "tools", "synoptik.sh"), "status | structure | help"],
                             root, "the systems, console commands and test count")
    surface = command_output(["sbcl", "--script", os.path.join(root, "tools", "test", "surface.lisp")],
                             root, "the analyzers, types, operations and MCP tools")
    systems = structure_systems(console, root)
    commands = console_commands(console)
    return (["", "Read from the tree by tools/test/readme-figures.py: the status, structure and",
             "help commands of tools/synoptik.sh, and tools/test/surface.lisp. Edit those, not",
             "this block.", "", FENCE + "text",
             "systems (%d)" % len(systems)] + wrapped_names(systems)
            + ["", "tests (counted by the index, not by running the suite)",
               "  " + tests_text(console), "",
               "console commands (%d)" % len(commands)] + wrapped_names(commands)
            + [""] + surface.rstrip("\n").split("\n") + [FENCE])


def commit_header(root):
    """The first line of the block: the commit and its date, and a note when the
    working tree differs from the commit in a file other than README.md."""
    short = command_output(["git", "rev-parse", "--short", "HEAD"], root, "the commit").strip()
    day = command_output(["git", "show", "-s", "--format=%cs", "HEAD"], root, "the commit date").strip()
    changed = command_output(["git", "status", "--porcelain", "--", ".", ":(exclude)README.md"],
                             root, "the working tree's state").strip()
    return ("Figures taken at commit %s, committed %s%s."
            % (short, day, ", with uncommitted changes in the working tree" if changed else ""))


def marker_pair(lines):
    """The indexes of the begin and end marker lines, or None when README.md does not
    hold exactly one of each with the begin first."""
    begins = [i for i, line in enumerate(lines) if line.strip() == BEGIN]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(begins) == 1 and len(ends) == 1 and begins[0] < ends[0]:
        return begins[0], ends[0]
    return None


def first_difference(held, wanted, first_line):
    """A sentence naming the first line where HELD (the block's figures, which start at
    README line FIRST_LINE) and WANTED differ, or None when they are equal."""
    for offset in range(max(len(held), len(wanted))):
        have = held[offset] if offset < len(held) else None
        want = wanted[offset] if offset < len(wanted) else None
        if have != want:
            return ("README.md line %d: the block holds %s; regenerating gives %s."
                    % (first_line + offset,
                       "nothing (the block ends)" if have is None else repr(have),
                       "nothing (the block ends)" if want is None else repr(want)))
    return None


def main():
    arguments = sys.argv[1:]
    if arguments not in ([], ["--check"]):
        print("usage: readme-figures.py [--check]", file=sys.stderr)
        sys.exit(3)
    path = os.path.join(checkout_dir(), "README.md")
    with open(path, encoding="utf-8", newline="") as handle:
        lines = handle.read().split("\n")
    pair = marker_pair(lines)
    if pair is None:
        print("README.md does not hold one %s line followed by one %s line." % (BEGIN, END),
              file=sys.stderr)
        sys.exit(2)
    begin, end = pair
    try:
        wanted = figure_lines(checkout_dir())
        header = commit_header(checkout_dir())
    except FigureError as problem:
        print(problem, file=sys.stderr)
        sys.exit(3)
    if arguments == ["--check"]:
        difference = first_difference(lines[begin + 2:end], wanted, begin + 3)
        if difference:
            print(difference, file=sys.stderr)
            sys.exit(1)
        print("README.md: the figures are current.")
        sys.exit(0)
    updated = lines[:begin + 1] + [header] + wanted + lines[end:]
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write("\n".join(updated))
    print("README.md: %s" % header)
    sys.exit(0)


if __name__ == "__main__":
    main()
