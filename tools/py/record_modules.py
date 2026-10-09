"""Which import names each requested distribution installed. DES-0055 D7, R7.

    python3 -I -B record_modules.py <site-packages> <name> ...

Prints {name: [module, ...]} as one line of JSON, for the asked names that are
installed there and own at least one module. Loom's init runs this to PROPOSE a
dependency-modules: block; nothing here is an index input.

A venv is untrusted data. This lists the *.dist-info directories under the one
path given and nothing is added to sys.path, so no .pth file is processed and
nothing in site-packages is imported or executed. Each RECORD is read as bounded
text and parsed here; METADATA is never read, because the distribution's name is
taken from its directory name. importlib.metadata is not used: its public calls
read a RECORD or METADATA whole, and its directory lookup is private.
"""
import json
import os
import sys

MAX_RECORD_BYTES = 8 * 1024 * 1024
MAX_LINES = 200000
MAX_MODULES = 2000
SKIPPED_DIRECTORIES = ("__pycache__", "bin")


def name_key(name):
    """PEP 503 normalisation: lower case, each run of - _ . made one -."""
    out, in_run = [], False
    for c in name.lower():
        if c in "-_.":
            if not in_run:
                out.append("-")
            in_run = True
        else:
            out.append(c)
            in_run = False
    return "".join(out)


def record_paths(text):
    """The relative .py paths a RECORD lists, as lists of path parts."""
    paths = []
    for line in text.splitlines()[:MAX_LINES]:
        if line.startswith('"'):
            end = line.find('"', 1)
            path = line[1:end] if end > 0 else ""
        else:
            path = line.split(",", 1)[0]
        parts = path.split("/")
        if not path.endswith(".py") or path.startswith("/"):
            continue
        if any(p in ("", ".", "..") or p in SKIPPED_DIRECTORIES
               or p.endswith(".dist-info") for p in parts):
            continue
        paths.append(parts)
    return paths


def module_of(parts, files):
    """The dotted name the file PARTS belongs to: the first directory from the
    top holding an __init__.py, else the module file itself. google/auth/x.py is
    google.auth when only google/auth has an __init__.py."""
    for depth in range(1, len(parts)):
        if tuple(parts[:depth]) + ("__init__.py",) in files:
            return ".".join(parts[:depth])
    stem = parts[-1][:-3]
    if stem == "__init__":
        return None
    return ".".join(parts[:-1] + [stem])


def modules(paths):
    files = {tuple(p) for p in paths}
    names = {module_of(p, files) for p in paths}
    names = {n for n in names if n and all(x.isidentifier() for x in n.split("."))}
    return sorted(names)[:MAX_MODULES]


def distribution_key(directory):
    """The normalised name of a NAME-VERSION.dist-info directory, else None."""
    if not directory.endswith(".dist-info"):
        return None
    stem = directory[: -len(".dist-info")]
    return name_key(stem.rpartition("-")[0] or stem)


def read_record(path):
    with open(path, "rb") as handle:
        return handle.read(MAX_RECORD_BYTES).decode("utf-8", "replace")


def main(argv):
    site_packages, asked = argv[1], {name_key(n) for n in argv[2:]}
    found = {}
    try:
        entries = sorted(os.listdir(site_packages))
    except OSError:
        entries = []
    for entry in entries:
        key = distribution_key(entry)
        record = os.path.join(site_packages, entry, "RECORD")
        if key not in asked or not os.path.isfile(record):
            continue
        try:
            found.setdefault(key, set()).update(modules(record_paths(read_record(record))))
        except OSError:
            continue
    print(json.dumps({k: sorted(v) for k, v in found.items() if v}))


if __name__ == "__main__":
    main(sys.argv)
