# Installing Loom

This takes an Ubuntu machine from nothing to a passing test suite and a `loom>`
prompt, then to a background service that Claude Code can reach. Loom is a
source tree that SBCL loads when you run it. There is no build step and no
installer to run.

Every command below is either marked NOT RUN HERE, with the reason, or was
run exactly as written inside a sandbox with an empty home directory. The last
section says what that run proves and what it does not.

## What has to be on the machine

| Program | Ubuntu package | Version tested | What needs it |
| --- | --- | --- | --- |
| SBCL | sbcl | 2.2.9 (2:2.2.9-1ubuntu2) | everything. No other version was run, and no minimum is claimed. |
| git | git | 2.43.0 | cloning, and Loom reads a tree's `.gitignore` through it. |
| curl | curl | 8.5.0 | fetching the Quicklisp installer. |
| python3 | python3 | 3.12.3 | the Python analyzer, optional. See "Without node or python3". |
| node | nodejs | 18.19.1 and 24.18.1 | the JavaScript analyzer, optional. |
| libyaml | libyaml-0-2 | 0.2.5 | the YAML reader, through CFFI. |
| libssl | libssl3t64 | 3.0.13 | the HTTP server and client libraries, through CFFI. |
| bubblewrap | bubblewrap | 0.9.0 | only tools/test/clean-room.sh. |

The operating system tested was Ubuntu 24.04.1 LTS under WSL2. On that release
libssl3 has no installable package of its own: `apt-cache policy libssl3`
prints `Candidate: (none)`, and the package that provides it is libssl3t64.

Two Ubuntu packages are not in the table because they are already there on
most machines: ca-certificates, which curl needs to fetch over https, and the
SBCL contribs, which ship inside the sbcl package.

### Install the packages

NOT RUN HERE. The sandbox shares the host's `/`, so it cannot show an install,
and it has no root. No fresh Ubuntu machine was set up for this file.

```sh not-run
sudo apt update
sudo apt install sbcl git curl python3 nodejs libyaml-0-2 libssl3t64 ca-certificates
```

What was checked is that each name exists and is installed on the machine this
file was written on, with the versions in the table. The commands below were
run in the sandbox, which sees that machine's packages.

```sh
dpkg -s sbcl git python3 nodejs libyaml-0-2 libssl3t64 curl | grep -E '^(Package|Version):'
sbcl --version
git --version
python3 --version
node --version
python3 -c 'import ast; print(ast.unparse(ast.parse("x=1")))'
/sbin/ldconfig -p | grep -E 'libyaml-0.so.2|libssl.so.3'
```

The `python3 -c` line prints `x = 1`. The Python documentation says
`ast.unparse` is new in 3.9, which makes this line a first check.

### Python: 3.10 or later

The Python analyzer runs tools/py/extract.py with `python3 -I -B`. The script
calls `ast.unparse`, which needs 3.9, and `collect_node` names `ast.MatchAs`,
`ast.MatchStar` and `ast.MatchMapping` without a guard. The pattern-matching
nodes were added in 3.10, so the floor the script reads as is 3.10. To see what
that does, the script was run on python3 3.12.3 with those names deleted from
`ast`. It answered `AttributeError: module 'ast' has no attribute 'MatchAs'`
for the one-line file `x = 1`. That simulates 3.9 for those names only. No
interpreter older than 3.12.3 was run.

### node: two versions

The JavaScript analyzer starts the program named `node`, so the first `node` on
the PATH of the Loom process is the one used.

This machine has two. Ubuntu's nodejs package installs /usr/bin/node, version
18.19.1. nvm installs a second under the home directory, version 24.18.1, and
puts it first on PATH in an interactive shell. The analyzer's test system,
loom-analyzer/test, passed 1358 of 1358 under each, run alone with that node
first on PATH. The whole suite also passed under 18.19.1 in the sandbox, which
sees only /usr/bin/node. No other version was run.

The service is started by systemd, not by your shell. The unit sets no
`Environment=` line, so the `node` it finds comes from the PATH of the systemd
user manager. `systemctl --user show-environment` prints that PATH. On this
machine it was the Ubuntu default, without nvm's directory, so the service
would use /usr/bin/node.

## Quicklisp

Quicklisp supplies every Lisp library. Loom's scripts load
`~/quicklisp/setup.lisp` by that name, so Quicklisp has to be installed in its
default place. They run SBCL with `--script`, which reads no init file, so
`(ql:add-to-init-file)` is not needed. The installer is fetched from
beta.quicklisp.org. Quicklisp's own page, quicklisp.org, describes how to check
its signature; that was not done here.

```sh
cd ~
curl -fsSL -o quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp
sbcl --non-interactive --load quicklisp.lisp --eval '(quicklisp-quickstart:install)'
```

The run for this file installed Quicklisp dist version 2026-01-01. Running the
installer a second time over an existing ~/quicklisp fails with a backtrace.

## Clone and run the suite

Replace `<repository-url>` with the address of this repository. Any directory
will do; the examples use the home directory.

```sh
git clone <repository-url> Loom
cd Loom
tools/loom-test.sh
```

The first run downloads the libraries, then compiles Loom's twelve systems and
runs their tests. It took 323 seconds in the sandbox, from an empty Quicklisp.
It ends with `12 of 12 systems passed.` and each system's `Pass:` and `Fail:`
counts above that.

### The libraries it downloads

The `.asd` files of the twelve systems and their test systems name thirteen
libraries outside Loom. `asdf:system-depends-on` printed this list:

| Library | Declared by |
| --- | --- |
| babel | loom-embed |
| bordeaux-threads | loom-utils, loom-ontology, loom-graph, loom-analyzer, loom-workspace, loom-serve |
| cl-json | loom-embed, loom-analyzer, loom-workspace, loom-serve, loom-rest, loom-mcp |
| cl-yaml | loom-analyzer |
| drakma | loom-embed |
| eclector | loom-analyzer |
| fiveam | the twelve test systems |
| hunchentoot | loom-serve, loom-rest, loom-mcp |
| random-uuid | loom-ontology, loom-workspace, loom-serve |
| st-json | loom-workspace |
| stem | loom-knowledge |
| uiop | loom-analyzer, loom-docstore, loom-workspace |
| usocket | loom-embed |

uiop ships with ASDF, so Quicklisp does not fetch it. The other twelve are in
the download. Quicklisp fetched 50 releases in all, and the other 38 are their
dependencies. This is `ls ~/quicklisp/dists/quicklisp/software` after the first
run, on dist 2026-01-01:

```text
acclimation-20241012-git               introspect-environment-20241012-git
alexandria-20241012-git                ironclad-v0.61
asdf-flv-version-2.2                   iterate-release-d27d7ff4-git
babel-20260101-git                     lisp-namespace-20221106-git
bordeaux-threads-v0.9.4                md5-20210630-git
cffi-20260101-git                      mfiano-utils-20230214-git
chipz-20230618-git                     parse-declarations-20101006-darcs
chunga-20260101-git                    parse-number-v1.8
cl+ssl-20260101-git                    puri-20201016-git
cl-base64-20201016-git                 random-uuid-20220707-git
cl-fad-20220220-git                    rfc2388-20180831-git
cl-json-20220707-git                   seedable-rng-20220707-git
cl-libyaml-20201220-git                serapeum-20260101-git
cl-pcg-20201016-hg                     split-sequence-v2.0.1
cl-ppcre-20250622-git                  st-json-20210630-git
cl-yaml-20260101-git                   stem-20150608-git
closer-mop-20260101-git                string-case-20180711-git
drakma-v2.0.10                         trivia-20260101-git
eclector-20260101-git                  trivial-backtrace-20230214-git
fiveam-20241012-git                    trivial-cltl2-20211230-git
flexi-streams-20241012-git             trivial-features-20250622-git
global-vars-20141106-git               trivial-file-size-20250622-git
hunchentoot-v1.3.1                     trivial-garbage-20231021-git
                                       trivial-gray-streams-20241012-git
                                       trivial-macroexpand-all-20171023-git
                                       type-i-20230214-git
                                       usocket-0.8.9
```

Release names carry the dist's snapshot date, so a later dist prints
different suffixes.

These commands list what was downloaded:

```sh
ls ~/quicklisp/dists/quicklisp/software
ls ~/quicklisp/dists/quicklisp/software | wc -l
```

Two of the downloads load a C library when Loom starts: cl-libyaml opens
libyaml-0.so.2 and cl+ssl opens libssl.so.3. Both packages are in the table
above. A machine without them was not run.

## The console

Start SBCL on loom.lisp, naming the tree to index. The pipe below feeds it two
commands, so it runs without a terminal. For the interactive prompt, run
`sbcl --script loom.lisp "$PWD"` on its own and type the commands yourself.

```sh
printf 'status\nstop\n' | sbcl --script loom.lisp "$PWD"
tools/loom.sh 'status | check'
```

`status` prints the file, entity and relationship counts of the tree it
indexed, and `check` prints rule violations and unresolved document references.
tools/loom.sh starts a console, runs the commands you give it and stops.
`help` at the prompt prints the full list.

## Without node or python3

Neither is needed to build or test Loom. Without one, files in that language
are still indexed as files, but their definitions are not read. Four things
back this up.

Two analyzer tests set the program name to one that does not exist, through
`*python-program*` and `*node-program*`, and assert the result.
`a-missing-interpreter-is-recorded-not-fatal` (Python) and
`the-toolchain-being-absent-is-recorded-not-fatal` (JavaScript) assert that the
file entity exists, that its `:analysis-failed-p` is true, that its
`:analysis-error` names the missing program, and, for Python, that the file
yields no function.

Two workspace tests cover `init`, which uses python3 to read a virtual
environment. `no-venv-means-every-entry-is-commented-and-no-child-starts` and
`a-python-that-cannot-start-leaves-every-entry-commented` assert that an
unusable python3 leaves every proposed entry commented out as
`# unverified: spelling only`.

The tests that need a live interpreter skip when it is missing. The skip
messages read `node is not on PATH` and `python3 is not on PATH`.

Both were also removed at once for a full run. A directory holding a link to
every program in /usr/bin except node, python3 and their relatives was the only
entry on PATH. `tools/loom-test.sh -v` then printed `12 of 12 systems passed.`
with 180 skipped tests (analyzer 140, workspace 38, rest 2) and no failure. On
this tree, `tools/loom.sh 'status'` under that PATH reported the same 524 files
and `unparsed : 19 files the analyzer could not read`. With both programs it
reported `unparsed : 0` and 5937 entities, against 5359 without them.

## Install the commands and the background service

NOT RUN HERE. These write to the machine: links on PATH, a systemd user unit,
and the unit's enabled state. They were read, not run. The resident service on
this machine's port 4780 belongs to its owner, so nothing here started,
stopped or restarted a service either.

With no arguments, tools/loom-install.sh links into `/usr/local/bin` only if
you can write there. Otherwise it writes nothing, prints two commands to choose
from, and exits 1, because it never uses sudo itself. Both `/usr/local/bin` on
this machine and the sandbox's read-only `/` are in the second case, so this
command was run:

```sh
tools/loom-install.sh
```

These are the two choices it prints, both NOT RUN HERE:

```sh not-run
tools/loom-install.sh --dir ~/.local/bin
sudo tools/loom-install.sh --dir /usr/local/bin
tools/loom-serve.sh install
```

- The first links for you alone. Ubuntu puts `~/.local/bin` on PATH at login
  only if the directory exists then, so the script prints a note when it is not
  on PATH yet. It then runs `tools/loom-serve.sh install` itself.
- The second links for everyone. Under sudo it skips the unit, because a user
  unit belongs to a login session, and prints the third command to run as
  yourself without sudo.
- Both create the links `loom` and `loom-serve` as symbolic links into the
  clone, never as copies. Moving the clone breaks them.

`tools/loom-serve.sh install` needs a user systemd manager. On WSL that means
systemd is enabled in /etc/wsl.conf; this machine has `systemd=true`. It
writes `~/.config/systemd/user/loom.service` (or `$XDG_CONFIG_HOME/systemd/user`
when that is set), runs `systemctl --user daemon-reload`, and starts nothing.
The unit runs `tools/loom-serve.sh serve` from the clone, with the clone as its
working directory, restarts on failure after 5 seconds, and is wanted by
default.target. The clone's directory name becomes the repository name the
tools take, so a clone named Loom is the repository `Loom`.

It then prints the two commands it leaves to you:

```sh not-run
systemctl --user enable --now loom.service
loginctl enable-linger "$USER"
```

The first enables the unit and starts it. The second is optional: without it
the user manager stops with your last login session and takes the service
with it. The loom-serve.sh comments give 40 to 90 seconds for the first start,
which compiles every system before it listens.

Once the unit is enabled, tools/loom-serve.sh start, stop, restart and
update hand the verb to systemctl. `tools/loom-serve.sh update` after a change
to Loom's source restarts the service only when the source is newer than the
running image.

## Register it with Claude Code

NOT RUN HERE. No Claude Code configuration was changed.

The file .mcp.json at the root of the clone registers an HTTP server named
`loom` at `http://127.0.0.1:4780/mcp`. The service must be running before a
Claude Code session opens, because Claude Code resolves its MCP servers once,
when the session opens. A service that the session's own first tool call starts
has missed that, and the `loom_*` tools are absent for the whole session.
That is why the unit above is worth installing. CLAUDE.md, under "Running it as
a service", records the same.

Claude Code run inside the clone reads .mcp.json from there. To register the
server for a session started elsewhere, the syntax below comes from
`claude mcp add --help` on Claude Code 2.1.296. It was not run:

```sh not-run
claude mcp add --transport http loom http://127.0.0.1:4780/mcp
```

Restart Claude Code after either. Whether Claude Code asks you to approve a
project's .mcp.json, and which command lists the servers it loaded, are from
its documentation and were not checked here.

## Security

The service binds 127.0.0.1 on port 4780 and has no authentication. It answers
403 to a request whose `Host` header is not `127.0.0.1`, `localhost` or `[::1]`
followed by the port it is on. A client that reaches it through another
hostname, a tunnel or a port mapping is refused for that reason. SECURITY.md
says what the service trusts and what the check does not stop.

## Optional: semantic search

Loom answers from lexical matching alone. Ollama and an embedding model add a
second ranking. The commands, the sizes and the measured effect are in
[README.md](README.md#optional-semantic-seeding). None of it was installed or
run for this file.

## How this was checked

The commands in the code blocks marked `sh` were run in this order by
tools/test/clean-room.sh with `--quicklisp fresh`, on 2026-10-11. The tree was
the commit f0b4885 plus the uncommitted INSTALL.md, copied into a git
repository inside the sandbox, so INSTALL.md was in the clone. The clone's
address was the sandbox's copy of the tree, standing in for `<repository-url>`.

The sandbox is bubblewrap with the host's `/` read-only and an empty `/home`.
It proves that nothing under the author's home directory was read: no symbolic
link to a sibling checkout in `~/quicklisp/local-projects`, no `~/.sbclrc`, no
nvm node. It shares the host's network, which is how the Quicklisp download
worked. It does not prove the package list, because `/` is the host's, so every
package in the table was present whether or not this file named it. Because the
script installs its own Quicklisp first, the run removed that copy before the
first command, so that the installer commands above were the ones that ran.

Not run, for the reasons given where each appears: the `apt` commands,
tools/loom-install.sh with `--dir`, `tools/loom-serve.sh install`, the two
systemctl and loginctl commands, `claude mcp add`, the service itself
(`tools/loom-serve.sh start` and `update`, the `/mcp` endpoint), Ollama, the
Quicklisp signature check, any Python older than 3.12.3, any SBCL other than
2.2.9, and a clean Ubuntu machine.
