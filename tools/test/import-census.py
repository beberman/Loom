#!/usr/bin/env python3
"""Count how a repository's import statements resolve, and why they do not.

    tools/test/import-census.py                 every watched repository
    tools/test/import-census.py front-end       one of them

REQ-0063 R4 and DES-0047 R14. Loom records every import specifier it finds on
the file that wrote it, and either links it to the file it names or records why
it could not. This prints both halves, per repository.

Four reasons an import resolves to nothing, and they need different repairs:

  external          Not a relative path, and no declared alias key matches it.
                    Usually correct -- it is a library.
  out-of-domain     Written under an alias key that some other area of the
                    repository declares and this one does not.
  unclaimed target  The alias rewrote it and the result names a file Loom does
                    not index. Usually a stylesheet or an image.
  unresolved        A relative path naming no indexed file.

The instrument starts the service itself and refuses to print a figure against
one it could not reach. RULE-0008: a measurement that did not happen must not
read like one that found nothing.
"""
import sys, os, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import service

CAUSES = ("external", "out-of-domain", "unclaimed-target", "unresolved")


def declared_alias_keys(root):
    """Every alias key the repository at ROOT declares, from its own config.

    Read from the file rather than from the service, because the status plist
    carries counts and not the declaration. A repository with no config, or one
    whose config has no domains, declares no keys and every specifier that is
    not relative is external.
    """
    path = os.path.join(root, ".loom", "frameworks.yaml")
    if not os.path.exists(path):
        return set()
    keys = set()
    in_aliases = False
    for line in open(path, encoding="utf-8"):
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        if stripped == "aliases:":
            in_aliases = True
            continue
        if in_aliases:
            # An alias line is indented further than the `aliases:' key and
            # holds `key: target'. Anything else ends the block.
            if line.startswith(" ") and ":" in stripped and not stripped.startswith("-"):
                indent = len(line) - len(line.lstrip())
                if indent >= 6:
                    keys.add(stripped.split(":", 1)[0].strip())
                    continue
            in_aliases = False
    return keys


def alias_rooted(name, keys):
    """How many recorded specifiers begin with a declared alias key.

    The denominator DES-0047 R14 asks for. Counted from what :IMPORT-SOURCES
    actually holds rather than from a text scan of the tree, because the two
    disagree: the extractor records ImportDeclaration, ExportNamedDeclaration
    with a source, and ExportAllDeclaration, and records neither dynamic
    import() nor require().
    """
    if not keys:
        return None
    listing = service.get("/find?repository=%s&term=&entity-type=file&limit=5000" % name)
    if not listing:
        return None
    total = rooted = 0
    for entity in listing.get("entities", []):
        path = entity.get("name")
        if not path:
            continue
        detail = service.get("/describe?repository=%s&term=%s"
                             % (name, urllib.parse.quote(path, safe="")))
        if not detail:
            continue
        for specifier in (detail.get("properties") or {}).get("import-sources") or []:
            total += 1
            head = specifier.split("/", 1)[0]
            if head in keys:
                rooted += 1
    return {"specifiers": total, "alias-rooted": rooted}


def census(name, row):
    """One repository's import counts, from its status plist."""
    imports = row.get("unresolved-imports")
    if not imports:
        return {"name": name, "modules": False}
    counts = {cause: imports.get(cause, 0) for cause in CAUSES}
    return {
        "name": name,
        "root": row.get("root"),
        "modules": True,
        "resolved": imports.get("resolved", 0),
        "counts": counts,
        "recorded": imports.get("resolved", 0) + sum(counts.values()),
        "problems": row.get("domain-problems") or [],
    }


def report(result):
    if result["name"] and not result["modules"]:
        print("  %-14s no files in a language that has imports" % result["name"])
        return
    total = result["recorded"]
    resolved = result["resolved"]
    share = (100.0 * resolved / total) if total else 0.0
    print("  %-14s %d links drawn from %d specifiers that resolved or failed "
          "(%.1f%%)" % (result["name"], resolved, total, share))
    for cause in CAUSES:
        n = result["counts"][cause]
        if n:
            print("      %-18s %d" % (cause, n))
    for problem in result["problems"]:
        print("      declaration: %s" % problem)
    keys = declared_alias_keys(result.get("root") or "")
    if keys:
        counted = alias_rooted(result["name"], keys)
        if counted:
            print("      %d alias keys declared; %d of %d recorded specifiers "
                  "begin with one"
                  % (len(keys), counted["alias-rooted"], counted["specifiers"]))
            print("      the two totals differ because two files importing one "
                  "target draw one link")


def main():
    wanted = sys.argv[1:]
    watched = service.ensure(__file__, repositories=tuple(wanted))
    names = wanted or sorted(watched)
    print()
    print("imports recorded, and how they resolve")
    print()
    missing = []
    for name in names:
        held = service.resolve(watched, name)
        if held is None:
            missing.append(name)
            continue
        report(census(held, watched[held]))
    if missing:
        service.refused(__file__,
                        "the service holds no repository named "
                        + ", ".join(missing),
                        unmeasured="those repositories' imports")
    print()


if __name__ == "__main__":
    main()
