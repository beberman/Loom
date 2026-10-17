# Third-party licences

Synoptik is MIT-licensed. It loads 157 systems from 50 Quicklisp releases and
vendors two JavaScript packages. This file says what licence each declares.
It reports what the libraries' own files say. It does not say what any licence
requires of someone who redistributes Synoptik, and it is not legal advice.

The list is for Quicklisp dist 2026-01-01. Another dist can hold other
releases, other versions, and other declarations.

## Synoptik

[LICENSE](LICENSE) starts "MIT License" and says "Copyright (c) 2026 Brian
Eberman". The 24 Synoptik systems (twelve, and their twelve test systems) declare
`:license "MIT"` in their `.asd` files.

No GPL-family code is copied into this tree. A search of the 564 files git
tracked, before this file was added, for `GPL`, `LLGPL`, `General Public
License`, `Lesser General`, `copyleft` and `SPDX` matched only
DES-0033, REQ-0079 and PLAN-0061. Each match is prose about the libraries named
below. No tracked file holds a GPL-family licence header or text, and no tracked
file is named COPYING.
The only licence files tracked are `LICENSE` and the two under
`tools/js/vendor/` (see "Vendored JavaScript").

## What is in the list

The twelve systems and their twelve test systems were loaded the way
tools/synoptik-test.sh loads them, without running the tests.
`asdf:already-loaded-systems` then named 189 systems:

| Count | What |
| --- | --- |
| 24 | Synoptik's own systems |
| 157 | systems from Quicklisp releases, listed below |
| 4 | SBCL contribs: sb-bsd-sockets, sb-cltl2, sb-posix, sb-rotate-byte |
| 4 | asdf and uiop, which ship with ASDF; asdf-package-system, a system object with no source directory; and the Quicklisp client |

The Quicklisp client declares `:license "BSD-style"` in its `quicklisp.asd`. It
is not downloaded by the first run; the installer in INSTALL.md puts it there.

Each of the 157 systems' source directories lies in one of 50 release
directories under the Quicklisp software directory. These are the same 50
releases INSTALL.md lists as downloaded by the first tools/synoptik-test.sh. A
script compared the two lists and found them equal. The licence column is
`(asdf:system-license (asdf:find-system "name"))`, which is the `:license`
(or `:licence`) given in a `defsystem` form and nothing the library's other files say.
It answers NIL where a library states its licence another way. ironclad is the
one such library here; see below.
The table gives the declaration of each release's main system, and notes the
systems of that release that declare something else.

## By licence the .asd declares

Releases, grouped by the wording of the declaration. The grouping is this file's
reading of those strings.

| Declared | Releases |
| --- | --- |
| MIT or MIT-style | 22 |
| BSD | 15 |
| public domain, 0-clause, Unlicense, WTFPL or "GNU All Permissive" | 6 |
| LLGPL (trivia, type-i, lisp-namespace, trivial-cltl2) | 4 |
| "GNU Lesser General Public License" (puri) | 1 |
| "Probably LLGPL" (stem) | 1 |
| `asdf:system-license` answers nothing (ironclad, which names its licence in a class default; see below) | 1 |
| total | 50 |

## The LLGPL and LGPL libraries

Five libraries declare the LLGPL or the LGPL, and a sixth declares "Probably
LLGPL". Each is fetched by Quicklisp into the user's own Quicklisp directory
when the first run needs it. None is copied into this tree.

| Library | Systems | Pulled by | Declared in | What its own files say |
| --- | --- | --- | --- | --- |
| trivia | 6: trivia, trivia.balland2006, trivia.level0, trivia.level1, trivia.level2, trivia.trivial | synoptik-ontology (also synoptik-workspace, synoptik-serve) -> random-uuid -> mfiano-utils -> serapeum -> trivia | `trivia.asd` line 7: "LLGPL" | `LICENSE`: "Trivia is licensed under the terms of the Lisp Lesser GNU Public License (http://opensource.franz.com/preamble.html), known as the LLGPL." |
| type-i | 1 | trivia.balland2006 -> type-i | `type-i.asd` line 14: "LLGPL" | `README.org` line 91: "Licensed under the LLGPL License." No licence file. |
| lisp-namespace | 1 | type-i and trivia.level2 -> lisp-namespace | `lisp-namespace.asd` line 22: "LLGPL" | `README.org` line 224: "Licensed under the LLGPL License." No licence file. |
| trivial-cltl2 | 1 | serapeum/macro-tools and trivia.level2 -> trivial-cltl2 | `trivial-cltl2.asd` line 5: "LLGPL" | Nothing else. `README.md` does not mention a licence and the release has no licence file. |
| puri | 1 | synoptik-embed -> drakma -> puri | `puri.asd` line 12: `:licence "GNU Lesser General Public License"` | `LICENSE`: "PURI is licensed under the terms of the Lisp Lesser GNU Public License, known as the LLGPL. The LLGPL consists of a preamble (see below) and the Lessor GNU Public License 2.1 (LGPL-2.1)." `README` line 31 says the same. |
| stem | 1 | synoptik-knowledge | `stem.asd` line 14: "Probably LLGPL" | Nothing. See below. |

The chain from synoptik-ontology to trivia runs through mfiano-utils and
serapeum, which no Synoptik `.asd` names. `asdf:system-depends-on` gave it, and the same
query gave the other chains. drakma is a production dependency of synoptik-embed, which is Synoptik's
Ollama client, and not only of the test systems.

The `.asd` of puri and the licence file of puri word the licence differently:
the first says "GNU Lesser General Public License" and the second says LLGPL.
This file lists puri as the `.asd` declares it and reports the other wording
here.

### stem

`stem.asd` declares `:license "Probably LLGPL"`. The release holds `ReadMe.txt`,
`stem.asd`, `stem.lisp`, `output.txt` and `voc.txt`, and no licence file. None
of `ReadMe.txt`, `stem.asd` or `stem.lisp` has a copyright line or names a
licence. `ReadMe.txt` and the header of `stem.lisp` say the code is a hand
translation to Common Lisp of the Porter stemming algorithm by Steven M.
Haflich in February 2002, "offered in the hope it will be useful, but with no
warranty". Beyond the "Probably", the licence of stem is not stated anywhere in
the release. Synoptik keeps stem (PLAN-0061 D6). The "Probably" is the author's
word, and this file does not resolve it.

## Libraries for which asdf:system-license answers nothing

**ironclad** (release ironclad-v0.61, 90 systems). `asdf:system-license` answers
NIL for all 90. `ironclad.asd` line 17 does name a licence, `:license "BSD
3-Clause"`, but as a default initarg of the release's own system class, which
ASDF does not read as the system's licence. The release's `LICENSE` file reads "Copyright (c) 2004-2008, Nathan
Froyd", then "All rights reserved", then three conditions (retain the notice in
source, reproduce it in binary distributions, do not use the names of the
copyright holders to endorse), then a disclaimer of warranty. Those are the
conditions of a three-clause BSD licence. Its `README.org` says "Ironclad is
released under a MIT-like license". Quicklisp loads ironclad because
seedable-rng, which random-uuid needs, names it.

**cl+ssl/config** (a second system in the cl+ssl release) declares no licence.
The main system, cl+ssl, declares "MIT". The release's `LICENSE` file records
that the licence changed from LGPL to a Lisp-LGPL in December 2005 and to an
"MIT-style" licence in January 2007, and then gives the permission text of the
MIT-style licence.

## All 50 releases

The table was generated by a script that loads the systems and reads each
one's declared licence, and then pasted here. "Systems loaded" is the number of
systems from that release in the 189. The release names are directories under
the Quicklisp software directory.

| Release | Systems loaded | Licence the .asd declares |
| --- | --- | --- |
| acclimation-20241012-git | 1 | "BSD 2-clause, see file LICENSE.text" |
| alexandria-20241012-git | 1 | "Public Domain / 0-clause MIT" |
| asdf-flv-version-2.2 | 1 | "GNU All Permissive" |
| babel-20260101-git | 1 | "MIT" |
| bordeaux-threads-v0.9.4 | 1 | "MIT" |
| cffi-20260101-git | 1 | "MIT" |
| chipz-20230618-git | 1 | "BSD style" |
| chunga-20260101-git | 1 | "BSD" |
| cl+ssl-20260101-git | 2 | "MIT" (1 other system declares none) |
| cl-base64-20201016-git | 1 | "BSD-style" |
| cl-fad-20220220-git | 1 | "BSD-2-Clause" |
| cl-json-20220707-git | 1 | "MIT" |
| cl-libyaml-20201220-git | 1 | "MIT" |
| cl-pcg-20201016-hg | 1 | "MIT" |
| cl-ppcre-20250622-git | 1 | "BSD" |
| cl-yaml-20260101-git | 1 | "MIT" |
| closer-mop-20260101-git | 1 | "MIT-style license" |
| drakma-v2.0.10 | 1 | "BSD" |
| eclector-20260101-git | 1 | "BSD" |
| fiveam-20241012-git | 1 | "BSD" |
| flexi-streams-20241012-git | 1 | "BSD-2-Clause" |
| global-vars-20141106-git | 1 | "MIT" |
| hunchentoot-v1.3.1 | 1 | "BSD-2-Clause" |
| introspect-environment-20241012-git | 1 | "WTFPL" |
| ironclad-v0.61 | 90 | none by `asdf:system-license`; `ironclad.asd` names "BSD 3-Clause" in a class default |
| iterate-release-d27d7ff4-git | 1 | "MIT" |
| lisp-namespace-20221106-git | 1 | "LLGPL" |
| md5-20210630-git | 1 | "Public Domain" |
| mfiano-utils-20230214-git | 1 | "MIT" |
| parse-declarations-20101006-darcs | 1 | "MIT" |
| parse-number-v1.8 | 1 | "BSD 3-Clause" |
| puri-20201016-git | 1 | "GNU Lesser General Public License" |
| random-uuid-20220707-git | 1 | "MIT" |
| rfc2388-20180831-git | 1 | "Simplified BSD" |
| seedable-rng-20220707-git | 1 | "MIT" |
| serapeum-20260101-git | 13 | "MIT" |
| split-sequence-v2.0.1 | 1 | "MIT" |
| st-json-20210630-git | 1 | "BSD" |
| stem-20150608-git | 1 | "Probably LLGPL" |
| string-case-20180711-git | 1 | "3-clause BSD" |
| trivia-20260101-git | 6 | "LLGPL" |
| trivial-backtrace-20230214-git | 1 | "MIT Style license" |
| trivial-cltl2-20211230-git | 1 | "LLGPL" |
| trivial-features-20250622-git | 1 | "MIT" |
| trivial-file-size-20250622-git | 1 | "MIT" |
| trivial-garbage-20231021-git | 1 | "Public Domain" |
| trivial-gray-streams-20241012-git | 1 | "MIT" |
| trivial-macroexpand-all-20171023-git | 1 | "Unlicense" |
| type-i-20230214-git | 1 | "LLGPL" |
| usocket-0.8.9 | 1 | "MIT" |

## Vendored JavaScript

Two packages are copied into the tree under `tools/js/vendor/` and are
redistributed with it. The JavaScript analyzer loads them (`tools/js/extract.js`).

| Package | Version | Licence | Files |
| --- | --- | --- | --- |
| acorn | 8.18.0 | MIT | `tools/js/vendor/acorn/LICENSE`, which starts "MIT License" and "Copyright (C) 2012-2022 by various contributors (see AUTHORS)"; `package.json` declares "MIT" |
| acorn-jsx | 5.3.2 | MIT | `tools/js/vendor/acorn-jsx/LICENSE`, which starts "Copyright (C) 2012-2017 by Ingvar Stepanyan" and holds the MIT permission text with no title line; `package.json` declares "MIT" |

The versions are the `version` fields of the two `package.json` files.

## Not covered

This file does not examine SBCL itself, ASDF, the C libraries Synoptik reaches
through CFFI (libyaml and libssl, installed as Ubuntu packages per INSTALL.md),
node, python3, or Ollama. None is part of the Quicklisp set, and none is
copied into this tree.
