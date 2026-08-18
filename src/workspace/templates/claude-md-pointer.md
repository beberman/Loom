<!-- loom:begin -->

## Engineering knowledge: ask Loom before reading the tree

This repository is indexed by **Loom**, a knowledge engine that answers
questions about this code and the documents describing it: where something is
defined, what a change reaches, which decisions govern an area.

The service is at `{{ENDPOINT}}` (REST under `/v1/`, MCP at `/mcp`), and this
repository is registered with it as `{{REPOSITORY-NAME}}`. Every query names
the repository it means.

**Invoke the `loom` skill before starting work** — it is the authoritative copy
of how to query the index and how to write a document. Two things worth knowing
without it:

- Documents live under `{{DOCUMENT-DIRECTORY}}/`, as YAML, one directory per
  kind. `{{CONCEPT-ID}}` in `{{DOCUMENT-DIRECTORY}}/concepts/` has the
  conventions.
- When work lands, do not edit a status by hand. Run the transition command,
  which moves every document the plan implements and files it correctly.

<!-- loom:end -->
