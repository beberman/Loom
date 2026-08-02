#!/usr/bin/env python3
"""PreToolUse hook: decide the permission for Loom's driver scripts and sbcl.

Why this exists.  A Bash allow-list rule is not matched against the command
text.  Claude Code first asks a model to extract a "command prefix" from the
command, and matches the rules against that -- so the rule
Bash(tools/loom.sh:*) fires only if the extractor returns a prefix beginning
with tools/loom.sh.  It has three outcomes, and two of them lose:

    tools/loom.sh 'status'                  -> tools/loom.sh          matched
    tools/loom.sh 'find x | impact x 3'     -> command_injection_...  no match
    sbcl --script foo.lisp                  -> sbcl, or none          maybe

The extractor reports command_injection_detected for anything shaped like a
shell operator, and it does not care that the operator sits inside single
quotes where the shell will never see it.  tools/loom.sh takes a whole console
session as one quoted argument, so every multi-command invocation looks like
injection to it.  With defaultMode dontAsk a miss is not a prompt somebody can
approve -- it is a silent denial, which inside a subagent is a stall nobody
sees.

A PreToolUse hook runs before permission evaluation and short-circuits it, so
what it allows is decided by the regexes below rather than by a classifier.
That is the whole point: deterministic, and enumerable by reading this file.

What it allows.

  1. One of the three driver scripts, by relative, ./-relative or absolute
     path, with single-quoted arguments or -v.
  2. sbcl, bare or as /usr/bin/sbcl, with the argument forms Loom actually
     uses: --script, --load, --eval, --non-interactive and friends.

Both accept only two argument shapes: a single-quoted string, or a bare word
drawn from a character class with no shell metacharacter in it.  A
single-quoted string cannot contain a single quote, so no argument can close
its own quoting and append an operator; a bare word cannot introduce one
because the characters are not in the class.  A pipe, a redirect, a
substitution or a second command therefore cannot appear in a command this
hook allows.

Note what 2 does and does not narrow.  sbcl --eval and --script run arbitrary
Lisp, which can shell out, so this is not a tight sandbox -- settings.json
already carries Bash(/usr/bin/sbcl:*), and that decision is unchanged.  What
the hook adds is that the decision now holds every time instead of depending
on what the prefix extractor makes of a particular argument list.

Anything else produces no output and falls through to the normal permission
flow.  The hook never denies; it only short-circuits the cases it recognises.
"""

import json
import re
import sys

# A single-quoted string, or a bare word containing no shell metacharacter.
# Deliberately excludes $ ` | ; & < > ( ) ! # \ " ' * ? and whitespace.
SAFE_ARG = r"""(?:'[^']*'|[A-Za-z0-9_./=+:@,~-]+)"""

DRIVER = re.compile(
    r"""^\s*
        (?:\./|/home/beberman/lisp/Loom/)?
        tools/(?:loom|loom-test|next-doc-id)\.sh
        (?:\s+(?:-v|'[^']*'))*
        \s*$""",
    re.VERBOSE,
)

SBCL = re.compile(
    r"""^\s*
        (?:/usr/bin/)?sbcl
        (?:\s+""" + SAFE_ARG + r""")*
        \s*$""",
    re.VERBOSE,
)

RULES = (
    (DRIVER, "Loom driver script with single-quoted arguments only"),
    (SBCL, "sbcl with quoted or metacharacter-free arguments only"),
)


def decision(command):
    """The reason this command is allowed, or None to fall through."""
    for pattern, reason in RULES:
        if pattern.match(command):
            return reason
    return None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return
    if payload.get("tool_name") != "Bash":
        return
    reason = decision(payload.get("tool_input", {}).get("command", ""))
    if reason is None:
        return
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    sys.stdout.write("\n")


main()
