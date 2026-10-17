import {
  Boxes, Bug, FileText, Gavel, Lightbulb, ListChecks, PenTool, ScanEye, ShieldCheck,
  type LucideIcon,
} from "lucide-react";
import raw from "./fixture.json";
import type { Doc, Filters, Repo } from "./types";

export const DOCS: Doc[] = (raw as { docs: Doc[] }).docs;
export const REPOS: Repo[] = (raw as { repositories: Omit<Repo, "state">[] }).repositories.map((r) => ({ ...r, state: "ready" as const }));

// Ids are per repository (REQ-0073), so a document is known by its repository and id.
export const key = (d: Doc) => `${d.repo}/${d.id}`;

const PALETTE = ["#2563eb", "#059669", "#d97706", "#db2777", "#7c3aed", "#0891b2", "#dc2626", "#475569"];
export function repoColor(name: string, names: string[]): string {
  const i = names.indexOf(name);
  return PALETTE[(i < 0 ? names.length : i) % PALETTE.length];
}

// A reference is a bare id, in the document's own repository, or @repo/id.
export function refKey(ref: string, repo: string): string {
  return ref.startsWith("@") ? ref.slice(1) : `${repo}/${ref}`;
}

type Meta = { label: string; plural: string; icon: LucideIcon; color: string; column: number; creatable: boolean };

// column is the left-to-right order the map draws: what is wanted, the shape of
// the answer, the decisions, the steps, then defects and the rest.
export const TYPE_META: Record<string, Meta> = {
  REQ: { label: "Requirement", plural: "Requirements", icon: FileText, color: "#2563eb", column: 0, creatable: true },
  DES: { label: "Design", plural: "Designs", icon: PenTool, color: "#7c3aed", column: 1, creatable: false },
  DEC: { label: "Decision", plural: "Decisions", icon: Gavel, color: "#db2777", column: 2, creatable: false },
  PLAN: { label: "Plan", plural: "Plans", icon: ListChecks, color: "#059669", column: 3, creatable: false },
  BUG: { label: "Bug", plural: "Bugs", icon: Bug, color: "#dc2626", column: 4, creatable: true },
  REV: { label: "Review", plural: "Reviews", icon: ScanEye, color: "#d97706", column: 5, creatable: false },
  ARCH: { label: "Architecture", plural: "Architecture", icon: Boxes, color: "#0891b2", column: 6, creatable: false },
  CON: { label: "Concept", plural: "Concepts", icon: Lightbulb, color: "#ca8a04", column: 7, creatable: false },
  RULE: { label: "Rule", plural: "Rules", icon: ShieldCheck, color: "#475569", column: 8, creatable: false },
};
export const TYPE_ORDER = Object.keys(TYPE_META).sort((a, b) => TYPE_META[a].column - TYPE_META[b].column);

export const STATUSES = Array.from(new Set(DOCS.map((d) => d.status))).filter(Boolean).sort();
export const PRIORITIES = Array.from(new Set(DOCS.map((d) => d.priority))).filter(Boolean).sort();

export function tagCounts(docs: Doc[]): [string, number][] {
  const m = new Map<string, number>();
  for (const d of docs) for (const t of d.tags) m.set(t, (m.get(t) ?? 0) + 1);
  return [...m].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

// The title a document carries is a sentence. The map shows the part that names it.
export function shortTitle(title: string, max = 44): string {
  const cut = title.split(/[:;,]| because | which | and | so | -- /)[0].trim() || title;
  if (cut.length <= max) return cut;
  const clipped = cut.slice(0, max);
  return clipped.slice(0, Math.max(clipped.lastIndexOf(" "), 20)).trim() + "…";
}

export function indexByKey(docs: Doc[]): Map<string, Doc> {
  return new Map(docs.map((d) => [key(d), d]));
}

export type Edge = { from: string; to: string; kind: "refines"; resolved: boolean; crossRepo: boolean };

// refines runs from the document that answers to the one it answers. `affects`
// names code and is shown on the document, not drawn.
export function edgesOf(docs: Doc[], known: Doc[] = docs): Edge[] {
  const keys = new Set(known.map(key));
  const out: Edge[] = [];
  for (const d of docs)
    for (const t of d.refines) {
      const to = refKey(t, d.repo);
      out.push({ from: key(d), to, kind: "refines", resolved: keys.has(to), crossRepo: !to.startsWith(d.repo + "/") });
    }
  return out;
}

export function matches(d: Doc, f: Filters): boolean {
  if (f.repos.length && !f.repos.includes(d.repo)) return false;
  if (f.types.length && !f.types.includes(d.type)) return false;
  if (f.statuses.length && !f.statuses.includes(d.status)) return false;
  if (f.priority && d.priority !== f.priority) return false;
  if (f.tag && !d.tags.includes(f.tag)) return false;
  if (f.text) {
    const q = f.text.toLowerCase();
    if (!d.id.toLowerCase().includes(q) && !d.title.toLowerCase().includes(q)) return false;
  }
  return true;
}

// The matched documents and what they connect to within `hops` links, walking in
// one direction at a time: down to what refines them (designs, then plans) and up
// to what they refine. Turning sideways through a shared parent is not followed,
// since one hub document would otherwise pull in every sibling.
export function widen(all: Doc[], matched: Set<string>, hops: number): Set<string> {
  const keys = new Set(all.map(key));
  const up = new Map<string, string[]>();   // key -> what it refines
  const down = new Map<string, string[]>(); // key -> what refines it
  for (const d of all) {
    const refs = d.refines.map((r) => refKey(r, d.repo)).filter((r) => keys.has(r));
    up.set(key(d), refs);
    for (const r of refs) down.set(r, [...(down.get(r) ?? []), key(d)]);
  }
  const seen = new Set(matched);
  for (const edges of [up, down]) {
    let frontier = new Set(matched);
    for (let i = 0; i < hops; i++) {
      const next = new Set<string>();
      for (const k of frontier) for (const n of edges.get(k) ?? []) if (!seen.has(n)) { seen.add(n); next.add(n); }
      frontier = next;
    }
  }
  return seen;
}

export function nextId(docs: Doc[], repo: string, type: string): string {
  const max = Math.max(0, ...docs.filter((d) => d.repo === repo && d.type === type).map((d) => parseInt(d.id.split("-")[1], 10)));
  return `${type}-${String(max + 1).padStart(4, "0")}`;
}

export function todayIso(): string {
  return new Date().toISOString().slice(0, 10);
}

// The text of a document as the file would hold it. A prototype serialiser: the
// real one keeps the source and rewrites only what changed (DES-0057 D14).
export function toYaml(d: Doc): string {
  const list = (a: string[]) => `[${a.join(", ")}]`;
  const block = (k: string, v: string) => (v ? `${k}: |\n${v.split("\n").map((l) => (l ? "  " + l : "")).join("\n")}\n` : "");
  return [
    `id: ${d.id}`,
    `title: ${d.title}`,
    `status: ${d.status}`,
    d.priority ? `priority: ${d.priority}` : "",
    `date: ${d.date}`,
    `refines: ${list(d.refines)}`,
    `affects: ${list(d.affects)}`,
    `tags: ${list(d.tags)}`,
  ].filter(Boolean).join("\n") + "\n" + block("summary", d.summary) + block("body", d.body);
}
