# Installing Loom

This takes an Ubuntu machine from nothing to a passing test suite and a `loom>`
prompt, then to a background service that Claude Code can reach. Loom is a
source tree that SBCL loads when you run it. There is no build step and no
installer to run.

Every command below was run, or is marked NOT RUN HERE with the reason. The
commands were run inside a sandbox with an empty home directory, and one by one
on new Ubuntu 24.04.5 virtual machines on Google Compute Engine, twice. The last
section says what each run proves and what it does not.

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

The sandbox shares the host's `/`, so it cannot show an install, and it has no
root. These two lines were run on the virtual machine, a new
`ubuntu-2404-lts-amd64` image that held git, python3 and curl and had no sbcl
and no node. `apt update` took 15 s and the install took 148 s. The one change
was `-y` on the `apt install` line, because the run had no terminal to answer
apt's confirmation prompt. A person at a keyboard answers that prompt instead.

```sh
sudo apt update
sudo apt install sbcl git curl python3 nodejs libyaml-0-2 libssl3t64 ca-certificates
```

The versions in the table are the ones the virtual machine installed, and they
are the ones the sandbox saw on the author's machine: sbcl 2:2.2.9-1ubuntu2,
git 1:2.43.0-1ubuntu7.3, python3 3.12.3-0ubuntu2.1, nodejs 18.19.1+dfsg-6ubuntu5,
libyaml-0-2 0.2.5-1build1, libssl3t64 3.0.13-0ubuntu3.16 and curl
8.5.0-2ubuntu10.15. The checks below were run in both places.

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

Quicklisp supplies every Lisp library. Loom's scripts load Quicklisp through
quicklisp-setup.lisp at the root of the clone, which takes the first
`setup.lisp` it finds in `$LOOM_QUICKLISP`, then `~/quicklisp`, then
`/usr/local/lib/quicklisp`. For one user the installer below puts it in the
second place. They run SBCL with `--script`, which reads no init file, so
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

Any directory will do for one user; the examples use the home directory. A
machine with several users wants the clone somewhere all of them can read. See
"A machine with several users".

```sh
git clone https://github.com/beberman/Loom.git Loom
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

These write to the machine: links on PATH, a systemd user unit, and the unit's
enabled state. They were not run on the author's own machine or in the sandbox,
because the author's machine runs a service of its own on port 4780 that this
file did not touch. They were run on the virtual machine, which had no other
use, and the results are stated where each command appears.

With no arguments, tools/loom-install.sh links into `/usr/local/bin` only if
you can write there. Otherwise it writes nothing, prints two commands to choose
from, and exits 1, because it never uses sudo itself. `/usr/local/bin` was not
writable on the virtual machine, in the sandbox or on the author's machine, so
this command was run in all three:

```sh
tools/loom-install.sh
```

On the virtual machine it printed both commands, linked nothing in
`/usr/local/bin` and exited 1. The choice that was run there links for you
alone:

```sh
tools/loom-install.sh --dir ~/.local/bin
```

It created the symbolic links `loom` and `loom-serve` in `~/.local/bin`, each
pointing into the clone, and reported `linked 2, skipped 0`. It noted that
`~/.local/bin` was not on PATH yet. Ubuntu adds the directory to PATH at login
only if it exists then: in a login shell started after the directory existed,
`command -v loom loom-serve` printed both links. The script then wrote
`~/.config/systemd/user/loom.service`, reloaded the user manager and printed the
two commands below. Moving the clone breaks the links, which are never copies.

The other choice links into a directory every account has on its PATH. It needs
root, so the block is marked `not-run` for tools/test/clean-room.sh, which has
none:

```sh not-run
sudo tools/loom-install.sh --dir /usr/local/bin
```

On the second virtual machine (2026-10-12) it created two root-owned links,
`/usr/local/bin/loom` and `/usr/local/bin/loom-serve`, and `command -v loom
loom-serve` found both on a minimal PATH. It skipped the unit, because a user
unit belongs to a login session, and printed `tools/loom-serve.sh install` to run
as yourself without sudo. The links are not enough for other accounts. They point
into the clone, and a clone under a home directory cannot be read by another
account: Ubuntu 24.04 makes home directories 0750, and `sudo -u nobody
/usr/local/bin/loom-serve status` answered `Permission denied`. "A machine with
several users" below says where to clone instead.

`tools/loom-serve.sh install` needs a user systemd manager. The virtual machine
had one. On WSL it means systemd is enabled in /etc/wsl.conf. The command
writes `~/.config/systemd/user/loom.service` (or `$XDG_CONFIG_HOME/systemd/user`
when that is set), runs `systemctl --user daemon-reload`, and starts nothing.
The unit that was written runs `tools/loom-serve.sh serve` from the clone, with
the clone as its working directory, restarts on failure after 5 seconds, and is
wanted by default.target. The clone's directory name becomes the repository name
the tools take, so a clone named Loom is the repository `Loom`.

The script leaves two commands to you. Both were run on the virtual machine:

```sh
systemctl --user enable --now loom.service
loginctl enable-linger "$USER"
```

The first enables the unit and starts it. `loginctl show-user` then reported
`Linger=yes`. The second is optional: without it the user manager stops with
your last login session and takes the service with it. The first start on the
virtual machine (four vCPUs, one watched tree) answered `/v1/status` with 200
after 16 s. The comments in loom-serve.sh give 40 to 90 seconds for the first
start, a figure from a machine that watches several trees.

What the running service did on the virtual machine:

- `/v1/status` returned 200 with `Host` set to `127.0.0.1:4780`, `localhost:4780`
  and `[::1]:4780`. It returned 403 with `HOST-REFUSED` for `evil.example:4780`,
  `127.0.0.1:9999` and `127.0.0.1.evil.example:4780`, and for a raw request
  with no `Host` header.
- A JSON-RPC `initialize` to `/mcp` answered with protocol version 2025-06-18
  and `serverInfo` name `loom`. `tools/list` returned 16 tools. README.md lists
  19 because three, the `loom_repl_*` tools, exist and are never offered: no
  caller is granted the repl tier (SECURITY.md). A `tools/list` with a foreign
  `Host` got 403.
- `tools/loom-serve.sh update` with nothing changed printed `supervised by
  systemd and current; nothing to do`.
- A `find` for `next-document-id` through `/v1/find` returned the definition.
- After `sudo systemctl reboot` the service was running again. The journal shows
  the user manager starting `loom.service` at boot, and `/v1/status` answered
  200 within 16 s of the first poll. That is what `enable-linger` and the
  enabled unit are for.

Once the unit is enabled, tools/loom-serve.sh start, stop, restart and
update hand the verb to systemctl. `tools/loom-serve.sh update` after a change
to Loom's source restarts the service only when the source is newer than the
running image.

## A machine with several users

Everything above is for one user. A user unit cannot serve several: each
account's copy binds port 4780, and only one can. A machine shared by several
users runs one service, as a system unit under its own account, and every
user's Claude Code reaches it through the `.mcp.json` that already names
`http://127.0.0.1:4780/mcp`. BUG-0074 is the record.

Read "A machine with more than one user" in [SECURITY.md](SECURITY.md) first.
Every local user can query every tree the service watches and run its write
operations on any tree its account can write.

These commands were run on the second virtual machine, with the users `alice`
and `bob` made for the purpose. Each has a different reason:

1. Clone outside every home directory, as root, so that all accounts can read
   it. `/opt/loom` is 0755:

   ```sh not-run
   sudo git clone https://github.com/beberman/Loom.git /opt/loom
   ```

2. Install Quicklisp once for the machine, and download every library into it
   with the account that can write there. The accounts that use it cannot write
   to it. SBCL compiles into each account's own `~/.cache`, so the copy does not
   change. The twelve libraries are the table under "The libraries it
   downloads". It held 50 releases and `loom status` ran from it as `alice`, who
   had no `~/quicklisp`:

   ```sh not-run
   sudo sbcl --non-interactive --load ~/quicklisp.lisp \
        --eval '(quicklisp-quickstart:install :path #p"/usr/local/lib/quicklisp/")'
   sudo sbcl --noinform --non-interactive --load /usr/local/lib/quicklisp/setup.lisp \
        --eval '(ql:quickload (list :babel :bordeaux-threads :cl-json :cl-yaml :drakma :eclector :fiveam :hunchentoot :random-uuid :st-json :stem :usocket))'
   ```

3. Tell git that every account may use the clone. Without this, git refuses a
   tree its caller does not own: `status` printed `built from : commit unknown`
   and read no `.gitignore` for `alice`. With it she saw the commit and the full
   counts:

   ```sh not-run
   sudo git config --system --add safe.directory /opt/loom
   ```

4. Make the account the service runs as. It should own nothing else:

   ```sh not-run
   sudo useradd --system --create-home --home-dir /var/lib/loom --shell /usr/sbin/nologin loom
   ```

5. Write the unit and start it. The install checks the account, that it can run
   the clone, and that a Quicklisp exists for it, and it writes nothing if one
   is missing. On the virtual machine it refused as a normal user, refused with
   no `loom` account, and refused a clone under a home directory, each saying
   what to change. It wrote the unit for `/opt/loom`:

   ```sh not-run
   sudo /opt/loom/tools/loom-serve.sh install --system
   sudo systemctl enable --now loom.service
   ```

   The first start compiled for the `loom` account and answered `/v1/status`
   with 200 after 133 s. A start after that took 17 s. `ps` showed the process
   running as `loom`.

The service handles twice as many requests at once as the machine has
processors and takes four times as many open connections, and answers 503 to the
next connection. On an 8 processor machine that is 16 and 32. `LOOM_MAX_THREADS`
and `LOOM_MAX_ACCEPT` set the two numbers, for the unit with `systemctl edit
loom.service` (`Environment=LOOM_MAX_THREADS=20`). The accept limit must be the
larger, and when only the first is set the second is twice it. With 10 and 12 on
the virtual machine, 8 connections that sent nothing left `/v1/status` answering
200, and 20 of them made it answer 503. A container's CPU quota is not seen, so
a service in one counts the host's processors. BUG-0078.

`tools/loom-serve.sh` finds the system unit first. As `alice`, `status` reported
`running, code current` and `update` reported `supervised by systemd and current;
nothing to do`. `start`, `stop` and `restart` need root for a system unit, and
as `alice` each printed `sudo /opt/loom/tools/loom-serve.sh <verb>` and exited 1.
Run `sudo tools/loom-serve.sh update` after changing the clone's source.

### Three users at once

These were run on a third virtual machine (8 vCPUs, CPU only, Ollama 0.40.3 with
`nomic-embed-text`) with the accounts `alice`, `bob` and `carol`, against Loom's
own tree (5940 entities), watched from `/opt/loom`. The numbers are for that
machine.

- **Reboot.** After `sudo systemctl reboot` the unit was running as `loom` with
  nobody logged in, and `/v1/status` answered 200.
- **Reads.** Each account ran 8 clients for 20 s, 24 in all, over six queries.
  All 530 answered 200, and each query's body was identical for the three
  accounts. One client alone had a median of 9 ms and 20 requests a second.
  Twenty-four had a median of 250 ms, a 95th percentile of 4.3 s and 26 requests
  a second, so the queries run almost serially.
- **Semantic `context`.** With the vector store built, one client had a median
  of 156 ms and 6.3 requests a second. Eight had 411 ms and 18.7. Twenty-four had
  1.28 s and 18.0. The median is the client count divided by the throughput
  (24 / 18.5 = 1.3 s), so the delay is a queue behind a fixed rate.
- **Where the rate is set.** Ollama alone answered 35 embeddings a second at 1, 8
  and 24 clients, and its latency rose with the queue: 29 ms, 211 ms, 603 ms. Its
  log showed `OLLAMA_NUM_PARALLEL:1` and `OLLAMA_MAX_QUEUE:512`. Setting
  `OLLAMA_NUM_PARALLEL=4` changed neither figure (35 a second directly, 18.5
  through the service). With 24 clients `top` showed the service at 400% CPU and
  Ollama's `llama-server` at 336% on 8 vCPUs. On this machine both were limited
  by the CPUs, not by Ollama's queue. A machine with a GPU, or more cores, was
  not run.
- **Writes.** `set-status` from three accounts at once on three documents in
  a tree owned by `loom` was applied three times and the files stayed owned by
  `loom`. Three accounts on one document gave a consistent chain, each answer
  naming the previous status as its `from`, and the file held the last. The same
  request for a tree under `/opt/loom`, which `loom` cannot write, answered 400
  with `Permission denied` and changed nothing.
- **A reindex.** BUG-0079 records what readers saw while one account reindexed.
- **Connections.** BUG-0078 records the limits. One account holding 150
  connections open with no request made the next request from any account
  answer 503.
- **Not kept across a restart.** A tree added with `watch` after the service
  started is not watched again after `systemctl restart loom`. The unit watches
  the clone it runs from. Trees to keep watching go on the unit's command line,
  and this was not tried.

Not run: the `loom_*` tools from a signed-in Claude Code session, a GPU, and
what `complete` writes when the caller is not the service's account.

## Register it with Claude Code

The registration command was run on the second virtual machine (2026-10-12),
against the system unit from "A machine with several users". Claude Code 2.1.296
was installed there with Anthropic's installer, `curl -fsSL
https://claude.ai/install.sh | bash`, as a normal user, and nobody signed in. No
session was opened and no `loom_*` tool was called. The endpoint was also
exercised with `curl` (see "What the running service did" above).

The file .mcp.json at the root of the clone registers an HTTP server named
`loom` at `http://127.0.0.1:4780/mcp`. The service must be running before a
Claude Code session opens, because Claude Code resolves its MCP servers once,
when the session opens. A service that the session's own first tool call starts
has missed that, and the `loom_*` tools are absent for the whole session.
That is why the unit above is worth installing. CLAUDE.md, under "Running it as
a service", records the same.

Claude Code run inside the clone reads .mcp.json from there. To register the
server for a session started elsewhere, the syntax below comes from
`claude mcp add --help` on Claude Code 2.1.296. The block is marked `not-run`
for tools/test/clean-room.sh, which has no Claude Code, and the command was run
on the virtual machine:

```sh not-run
claude mcp add --transport http loom http://127.0.0.1:4780/mcp
claude mcp list
```

`add` printed `Added HTTP MCP server loom with URL: http://127.0.0.1:4780/mcp to
local config` and wrote `~/.claude.json`, under the project for the directory it
was run in. `list` printed `Checking MCP server health…` and then `loom:
http://127.0.0.1:4780/mcp (HTTP) - ✔ Connected`. Connected means the server
answered the handshake. It does not show a session offering the `loom_*` tools.

Restart Claude Code after either. Whether Claude Code asks you to approve a
project's .mcp.json is from its documentation and was not checked here.

## Security

The service binds 127.0.0.1 on port 4780 and has no authentication. It answers
403 to a request whose `Host` header is not `127.0.0.1`, `localhost` or `[::1]`
followed by the port it is on. A client that reaches it through another
hostname, a tunnel or a port mapping is refused for that reason. SECURITY.md
says what the service trusts and what the check does not stop.

## Optional: semantic seeding with Ollama

Loom answers from lexical matching alone. Ollama and an embedding model add a
second ranking, built from each definition's name and docstring. Nothing here is
needed for anything above. Every number below was measured on the second virtual
machine (2026-10-12, e2-standard-8 with no GPU, Loom indexing its own tree at
commit 25a9fb5 with the fixes of BUG-0075, BUG-0076 and BUG-0077 applied), and
the cases are in this repository, so they can be run again.

Install Ollama and pull the model. The installer is Ollama's own, run as root. It
downloaded into `/usr/local`, made an `ollama` account and a systemd unit, and
reported `No NVIDIA/AMD GPU detected. Ollama will run in CPU-only mode.` `zstd`,
which it uses, was already on the image. The machine's disk went from 2.9 GB to
5.3 GB used.

```sh not-run
curl -fsSL https://ollama.com/install.sh | sh
ollama pull nomic-embed-text
```

The install took 1m07 and the pull 9 s for 274 MB. Ollama 0.40.3 listened on
`127.0.0.1:11434`, which is where Loom looks, with that model, by default.

Nothing builds the store by itself on a service that has none. Ask for it:

```sh not-run
curl -X POST 'http://127.0.0.1:4780/v1/embed?repository=Loom'
```

The console command `embed` does the same. Loom's 3094 definitions took 229 s to
embed, 13.5 a second, and the store is two files of 9.5 MB and 0.2 MB.
README.md says a service that already has a store refreshes it as files change,
embedding only definitions whose name or docstring changed. That was not run.

While the build runs, `status` reports `embedding` and queries are answered
without the store. This was checked after BUG-0076: ten queries made during a
229 s build all answered 200 with the lexical seeds. Before that fix every one
answered 500.

What it bought, on Loom's own tree. The 450 cases are generated from the tree
by tools/test/make-cases.py and score a definition found from its own name, an
inflected form of it, or its docstring. The 44 vocabulary-mismatch cases are in
tools/test/cases/loom-mismatch.json, each a description that shares no word with
its answer, checked by tools/test/mismatch-check.lisp:

| Cases | Lexical only | With the store |
| --- | --- | --- |
| 150 by name | 120 (80.0%) | 144 (96.0%) |
| 150 by inflected name | 104 (69.3%) | 144 (96.0%) |
| 150 by docstring | 123 (82.0%) | 144 (96.0%) |
| 450 generated, all | 347 (77.1%) | 432 (96.0%) |
| 44 vocabulary mismatch | 0 (0.0%), 1 lenient | 8 (18.2%), 11 lenient |

The docstring row is the one the embedding is built from, so it favours the
store. The mismatch row is smaller than the 39 of 120 measured on the private
trees. Its 44 queries were written by Claude Sonnet 5.5 in the session that
found the bugs, which had read the tree.

A query's median time went from 113 ms to 152 ms, 40 queries each, with the 95th
percentile from 150 to 205 ms. With Ollama stopped, the first query took 2.07 s,
the 2 s connect timeout, and the next ones 0.08 s, each with a 200 and seeds.
The service remembers an absent Ollama for 60 s. After Ollama was started again
and 65 s passed, the median query time was back at 157 ms.

To run the figures again on a clone:

```sh not-run
sbcl --script tools/test/entity-dump.lisp "$PWD" > loom-entities.json
tools/test/make-cases.py Loom=loom-entities.json > loom-cases.json
tools/test/recall.py loom-cases.json
tools/test/recall.py tools/test/cases/loom-mismatch.json
```

The repository must be watched under the name `Loom`, which is the clone's
directory name. `recall.py` prints `Loom HAS NO VECTOR STORE` on a run with no
store, and waits for a repository that is still `embedding`.

On a machine with several users the store cannot go in the clone, which is
root's. The unit that `install --system` writes names a state directory
(`StateDirectory=loom`, `LOOM_STATE_DIR=/var/lib/loom`), and the store goes in
`/var/lib/loom/vectors/`. Without it the build ended `ready` with no store and
only `last-error: Can't create directory /opt/loom/src/embed/../../.loom` in
`status` (BUG-0077). With it, the store was written by the `loom` account after
243 s and the next start of the unit loaded it.

Not run: a GPU, any other embedding model, a tree larger than Loom's 3094
definitions, Ollama on a machine without `zstd`, and the semantic effect on any
tree that is not Loom.

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

The commands were run again, one at a time and in the order of this file, on a
Compute Engine virtual machine created for the purpose on 2026-10-11 and deleted
afterwards: an e2-standard-4 with a 30 GB disk, the image family
`ubuntu-2404-lts-amd64` (Ubuntu 24.04.5 LTS, kernel 7.0.0-1011-gcp). The tree
was commit aa06229 of the branch req-0079-open-source, delivered as a `git
bundle` copied over `scp`, because the repository was private and the machine
held no credential. The clone address in the `git clone` line was the bundle.
That run proves what the sandbox cannot:

- The package list is enough. Starting from the image, `sudo apt install` of the
  packages in the table was followed by the Quicklisp installer, the clone and
  `tools/loom-test.sh`, which printed `12 of 12 systems passed.` in 376 s with
  the same twelve pass counts as the sandbox (50, 46, 249, 496, 1358, 857, 1242,
  645, 261, 376, 123 and 58). Quicklisp downloaded the same 50 releases.
- The console indexed the clone: 528 files, 325 documents, 0 violations,
  0 unparsed files.
- The installation, the unit, the linger setting, the Host check, the `/mcp`
  endpoint and the restart after a reboot behaved as described above.

It does not prove that each package in the table is needed. The image already
held git, python3 and curl, so a machine without them was not run. It ran as
one user with sudo and a network. It was one release of one distribution.

A second virtual machine, created and deleted on 2026-10-12 with the same size,
disk and image, took commit b7f6b84 from the public address
`https://github.com/beberman/Loom.git`, with no bundle and no credential. It
ran the same commands in the same order. The result was the same: `12 of 12
systems passed.` in 365 s with the same twelve pass counts, 50 Quicklisp
releases, and 529 files, 325 documents, 0 violations and 0 unparsed in the
console. The links, the unit, linger and the Host checks behaved as described
above, and the service answered again, unstarted by anyone, after
`sudo systemctl reboot`. It then ran `sudo tools/loom-install.sh --dir
/usr/local/bin` and the section "A machine with several users", with two more
accounts. Those found the faults BUG-0074 records. The missing `cl-json` had not
shown before because tools/loom-test.sh downloads every library before the
console runs, and the git and permission faults appear only for an account that
does not own the clone.

Not run, for the reasons given where each appears: a signed-in Claude Code
session calling a `loom_*` tool, Claude Code run inside a clone to read
.mcp.json, Ollama, the Quicklisp signature check, any Python older than 3.12.3,
any SBCL other than 2.2.9, any Ubuntu release other than 24.04, WSL as a host for the unit, and a
machine without git, python3 and curl.
