# Private trees: measurements and fixtures in this repository that come from code that is not published

Four trees that Loom was built and measured against are private: game-server, front-end, lfia-accounting and the standalone utils library. A reader of this repository cannot check any of them out. Figures taken on them cannot be reproduced from this repository.

## Figures

Any figure in docs/, in a docstring or in a comment that names one of these trees was measured on that tree. No figure was changed or dropped when the repository was prepared for publication (REQ-0079 R3). 
CLAUDE.md, .claude/ and the templates `init` writes into other repositories name none of the trees. Every agent working in a clone reads them, and none tells a reader to watch a tree they do not have.

## Fixtures copied from the trees

Each fixture is a string in a test file. The tests assert what the analyzer does with the string, so the string being the real file is what makes the assertion evidence about that tree.

| File and lines | Fixture | Source |
| --- | --- | --- |
| `src/analyzer/test/js-analyzer.lisp` 802-822 | `*front-end-index-js*` | functions/index.js of front-end at commit ab34be6, "verbatim" by its docstring |
| `src/analyzer/test/js-analyzer.lisp` 824-833 | `*front-end-hello-js*` | functions/hello.js of front-end at the same commit, "verbatim" by its docstring |
| `src/analyzer/test/firebase-analyzer.lisp` 17-32 | `*lfia-firebase-json*` | lfia-accounting's firebase.json "as it stood when this step landed" |
| `src/analyzer/test/firebase-analyzer.lisp` 34-38 | `*lfia-firebaserc*` | lfia-accounting's .firebaserc, with the Firebase project id replaced by example-project |
| `src/analyzer/test/frameworks.lisp` 14-28 | `*game-server-frameworks*` | game-server's frameworks declaration, "verbatim in shape" by its docstring |
| `src/analyzer/test/frameworks.lisp` 290-316 | `*lfia-frameworks*` | lfia-accounting's .loom/frameworks.yaml "as written when this step landed" |

ab34be6 is a commit in front-end's repository. It is not an object in this one.

The project id was replaced in the fixture and in the assertion on it (`src/analyzer/test/firebase-analyzer.lisp` 36 and 85), in `src/process/test/console.lisp` 796 and 800, and in the completed documents DES-0054 and PLAN-0057 where the same value was quoted. A test that reads the value reads example-project.

Two groups of tests build a graph or a directory shaped like lfia-accounting and copy nothing from it: the Python specifier fixtures near line 1600 and the fan-out fixtures near line 1790 of `src/graph/test/resolve.lisp`.

The standalone utils library is the source of functions that were copied into this repository when the dependency on it was removed (REQ-0079 R1): `read-file` in `src/utils/files.lisp`, the list predicates in `src/serve/json.lisp` and `src/workspace/context-log.lisp`. Each comment above them says so. The library is not published, so the original cannot be diffed against the copy.

## Case files

tools/test/cases/known-item.json holds 450 cases: 274 against front-end and 176 against game-server. tools/test/cases/mismatch.json holds 120: 86 against front-end and 34 against game-server. Each case is `[repository, query, expected-name, family]`, and the expected name is an entity of one of those two trees. `tools/test/cases/mismatch.md` records how the 120 were written and the recall measured with them.

A case file for a tree you have is built with `tools/test/entity-dump.lisp` and `tools/test/make-cases.py`. The 450 were built that way from entity dumps of game-server and front-end. The 120 were written by a model and filtered by `tools/test/mismatch-check.lisp`, which reads entity dumps of the same two trees. Neither file can be rebuilt without them.

## Instruments that need the trees

These need a tree the reader does not have, and cannot run here as they stand:

- `tools/test/recall.py` takes a case file and watches every repository the file names. With `known-item.json` or `mismatch.json` that is front-end and game-server.
- `tools/test/seed-sheet.py` takes the same case files and the same service, and also needs the context log switched on.
- `tools/test/acceptance.py` holds 26 hand-written cases. 11 are against front-end, 6 against game-server, 3 against the utils library and 6 against Loom.
- `tools/test/mismatch-check.lisp` takes entity dumps named by repository, such as game-server and front-end, as arguments.
- `tools/test/summary-band.lisp` measures this tree with no arguments. Given `<root> <task>` pairs it measures those trees as well, and with game-server or front-end as a root it needs them.

`tools/test/recall.py` and `tools/test/seed-sheet.py` run against a case file built from this tree.

## Commit messages

111 of the 514 commits reachable from any ref name one of the three trees in the message. History is kept as it is, because rewriting it changes every hash the documents cite (REQ-0079 D3). `tools/test/release-scan.py --history` reads every message and prints them by commit.

## The SS citations

Files in src/ and docs/ cite sections of the architecture document as SS followed by a number: 371 occurrences on 343 lines in 79 files, naming 41 distinct section numbers. The document is `PHASE1-ARCHITECTURE.md` at the repository root. Its headings carry revision 3's numbers. Its last section, "Revision 1 section numbers", is a table from revision 1's numbers to revision 3's, and it lists the 14 numbers that name different sections in the two revisions. A citation of one of those 14 has to be read against the revision it was written for. The Word file that held the document was removed from the tree and is in git history.

## Finding the mentions

`tools/test/release-scan.py` reads the committed files. For each file and class it prints the class and the count of lines, and it ends with a table of lines and files per class. Its `private` class counts the lines that name game-server, lfia-accounting or front-end. A count there is a count of mentions and never makes the scan fail. The class does not count the utils library.

When this note was written the class counted 1462 lines in 225 files. A line is counted once however many names it holds. The bare words front and end are ordinary English, so the front-end pattern matches only `@front-end`, `/front-end` and `front-end/`.
