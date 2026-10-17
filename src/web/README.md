# synoptik-web

The web UI for Synoptik's documents (REQ-0080, DES-0057, PLAN-0062).

## Prototype (PLAN-0062 S0)

A clickable UI for review. It reads a fixture generated from this tree's
`docs/` and writes nothing: edits live in memory until the page reloads. There
is no service, proxy or plugin behind it.

    cd src/web && npm install
    cd apps/standalone
    npm run dev          # http://localhost:5173
    npm run build        # one self-contained dist/index.html, opens from disk

`npm run dev` and `npm run build` first run `scripts/make-fixture.py`, which
needs `python3` with PyYAML and writes `apps/standalone/src/fixture.json`
(gitignored).

What to try: the explorer's quick views and filters, the map and the list,
selecting a document to edit it, the YAML toggle, find and replace, `New`
(requirement or bug only), the agents panel with its three adapter levels, the
theme toggle, and a 360 px wide window.
