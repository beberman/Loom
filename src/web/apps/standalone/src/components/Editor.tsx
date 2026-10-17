import { useEffect, useMemo, useRef, useState } from "react";
import { Check, Code2, Redo2, Replace, Save, Undo2, X, AlertTriangle, FileWarning } from "lucide-react";
import { STATUSES, PRIORITIES, indexByKey, refKey, toYaml, todayIso } from "../data";
import type { Doc } from "../types";

type Block = { kind: "heading" | "item" | "para"; text: string };

const HEADING = /^[A-Z][A-Z0-9 ,&'/()\-]{3,}$/;
const ITEM = /^R\d+[a-z]?\s/;

// Prototype structure: the real editor derives this from the YAML source and
// leaves untouched text byte-for-byte (DES-0057 D14, D15).
function parse(text: string): Block[] {
  return text.split(/\n{2,}/).filter((b) => b.trim()).map((t) => {
    const first = t.split("\n")[0];
    if (!t.includes("\n") && HEADING.test(t.trim())) return { kind: "heading" as const, text: t.trim() };
    if (ITEM.test(first)) return { kind: "item" as const, text: t };
    return { kind: "para" as const, text: t };
  });
}
const join = (b: Block[]) => b.map((x) => x.text).join("\n\n");

function Auto({ value, onChange, className }: { value: string; onChange: (v: string) => void; className?: string }) {
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => { const el = ref.current; if (el) { el.style.height = "0"; el.style.height = el.scrollHeight + "px"; } }, [value]);
  return <textarea ref={ref} rows={1} value={value} onChange={(e) => onChange(e.target.value)}
    className={`w-full resize-none rounded-md border border-transparent bg-transparent px-2 py-1 outline-none hover:border-line focus:border-accent ${className ?? ""}`} />;
}

export default function Editor({
  doc, all, onSave, onStatus, toast,
}: { doc: Doc; all: Doc[]; onSave: (d: Doc) => void; onStatus: (s: string) => void; toast: (m: string) => void }) {
  const [draft, setDraft] = useState<Doc>(doc);
  const [past, setPast] = useState<Doc[]>([]);
  const [future, setFuture] = useState<Doc[]>([]);
  const [raw, setRaw] = useState(false);
  const [find, setFind] = useState("");
  const [repl, setRepl] = useState("");
  const [showFind, setShowFind] = useState(false);
  const [conflict, setConflict] = useState(false);
  const [checkOpen, setCheckOpen] = useState(false);

  useEffect(() => { setDraft(doc); setPast([]); setFuture([]); }, [doc.id, doc.repo]);

  const change = (next: Doc) => { setPast((p) => [...p.slice(-99), draft]); setFuture([]); setDraft(next); };
  const undo = () => { const p = past[past.length - 1]; if (!p) return; setFuture((f) => [draft, ...f]); setPast(past.slice(0, -1)); setDraft(p); };
  const redo = () => { const n = future[0]; if (!n) return; setPast((p) => [...p, draft]); setFuture(future.slice(1)); setDraft(n); };
  const dirty = JSON.stringify(draft) !== JSON.stringify(doc);

  const summaryBlocks = useMemo(() => parse(draft.summary), [draft.summary]);
  const bodyBlocks = useMemo(() => parse(draft.body), [draft.body]);
  const byKey = useMemo(() => indexByKey(all), [all]);
  const resolves = (r: string) => byKey.has(refKey(r, doc.repo));

  const hits = find ? (draft.title + draft.summary + draft.body).split(find).length - 1 : 0;
  const replaceAll = () => {
    if (!find) return;
    change({ ...draft, title: draft.title.split(find).join(repl), summary: draft.summary.split(find).join(repl), body: draft.body.split(find).join(repl) });
    toast(`Replaced ${hits} occurrence${hits === 1 ? "" : "s"}`);
  };

  const refChecks = [...draft.refines.map((r) => ({ ref: r, kind: "refines" as const, ok: resolves(r) })),
    ...draft.affects.map((a) => ({ ref: a, kind: "affects" as const, ok: true }))];
  const problems = refChecks.filter((c) => !c.ok).length;

  const blocksEditor = (blocks: Block[], set: (t: string) => void) => (
    <div className="space-y-1">
      {blocks.map((b, i) => {
        const upd = (t: string) => set(join(blocks.map((x, j) => (j === i ? { ...x, text: t } : x))));
        if (b.kind === "heading")
          return <div key={i} className="pt-4"><Auto value={b.text} onChange={upd} className="text-xs font-bold uppercase tracking-wider text-mute" /></div>;
        if (b.kind === "item") {
          const m = b.text.match(/^(R\d+[a-z]?)\s+([\s\S]*)$/)!;
          return (
            <div key={i} className="flex gap-2">
              <span className="mt-1.5 h-fit rounded bg-accent/15 px-1.5 font-mono text-xs font-semibold text-accent">{m[1]}</span>
              <Auto value={m[2].replace(/\n\s+/g, " ")} onChange={(t) => upd(`${m[1]}  ${t}`)} className="text-sm leading-relaxed" />
            </div>
          );
        }
        return <Auto key={i} value={b.text} onChange={upd} className="text-sm leading-relaxed" />;
      })}
    </div>
  );

  return (
    <div className="flex h-full flex-col">
      <div className="flex flex-wrap items-center gap-1.5 border-b border-line p-2">
        <button className="btn" onClick={undo} disabled={!past.length} aria-label="Undo"><Undo2 size={16} /></button>
        <button className="btn" onClick={redo} disabled={!future.length} aria-label="Redo"><Redo2 size={16} /></button>
        <button className="btn" onClick={() => setShowFind(!showFind)} aria-label="Find and replace"><Replace size={16} /> <span className="hidden sm:inline">Find</span></button>
        <button className={`btn ${raw ? "!border-accent text-accent" : ""}`} onClick={() => setRaw(!raw)}><Code2 size={16} /> YAML</button>
        <button className="btn" onClick={() => setConflict(true)} title="Prototype: show what a refused save looks like"><FileWarning size={16} /> <span className="hidden sm:inline">Simulate conflict</span></button>
        <span className="flex-1" />
        {dirty && <span className="text-xs text-mute">unsaved</span>}
        <button className="btn btn-primary" disabled={!dirty} onClick={() => { onSave(draft); toast("Saved in memory. The prototype writes no file."); }}>
          <Save size={16} /> Save
        </button>
      </div>

      {showFind && (
        <div className="flex flex-wrap items-center gap-2 border-b border-line bg-line/20 p-2">
          <input className="input !w-40" placeholder="Find" value={find} onChange={(e) => setFind(e.target.value)} />
          <input className="input !w-40" placeholder="Replace with" value={repl} onChange={(e) => setRepl(e.target.value)} />
          <span className="text-xs text-mute">{find ? `${hits} match${hits === 1 ? "" : "es"}` : ""}</span>
          <button className="btn" disabled={!hits} onClick={replaceAll}>Replace all</button>
        </div>
      )}

      <div className="flex min-h-0 flex-1 flex-col lg:flex-row">
        <div className="min-h-0 flex-1 overflow-y-auto p-4">
          {raw ? (
            <pre className="whitespace-pre-wrap break-words rounded-lg bg-line/30 p-3 font-mono text-xs leading-relaxed">{toYaml(draft)}</pre>
          ) : (
            <>
              <Auto value={draft.title} onChange={(t) => change({ ...draft, title: t })} className="text-lg font-semibold leading-snug" />
              <div className="my-3 grid grid-cols-2 gap-3 sm:grid-cols-[1fr_1fr_2fr]">
                <label className="text-xs text-mute">Status
                  <select className="input mt-1 text-ink" value={draft.status} onChange={(e) => { change({ ...draft, status: e.target.value }); onStatus(e.target.value); }}>
                    {STATUSES.map((s) => <option key={s}>{s}</option>)}
                  </select>
                </label>
                <label className="text-xs text-mute">Priority
                  <select className="input mt-1 text-ink" value={draft.priority} onChange={(e) => change({ ...draft, priority: e.target.value })}>
                    <option value=""></option>{PRIORITIES.map((p) => <option key={p}>{p}</option>)}
                  </select>
                </label>
                <label className="col-span-2 text-xs text-mute sm:col-span-1">Date
                  <input className="input mt-1 text-ink" value={draft.date || todayIso()} onChange={(e) => change({ ...draft, date: e.target.value })} />
                </label>
              </div>
              <div className="mb-2 text-xs text-mute">Tags</div>
              <div className="mb-3 flex flex-wrap gap-1.5">
                {draft.tags.map((t) => (
                  <span key={t} className="chip">{t}
                    <button aria-label={`Remove ${t}`} onClick={() => change({ ...draft, tags: draft.tags.filter((x) => x !== t) })}><X size={12} /></button>
                  </span>
                ))}
                <input className="chip !min-h-0 w-28 outline-none" placeholder="add tag" onKeyDown={(e) => {
                  const v = e.currentTarget.value.trim();
                  if (e.key === "Enter" && v) { change({ ...draft, tags: [...draft.tags, v] }); e.currentTarget.value = ""; }
                }} />
              </div>
              <div className="mb-1 text-xs text-mute">Refines</div>
              <div className="mb-4 flex flex-wrap gap-1.5">
                {draft.refines.map((r) => (
                  <span key={r} className={`chip ${resolves(r) ? "" : "!border-red-500 text-red-500"}`}>
                    {!resolves(r) && <AlertTriangle size={12} />}{r}
                    <button aria-label={`Remove ${r}`} onClick={() => change({ ...draft, refines: draft.refines.filter((x) => x !== r) })}><X size={12} /></button>
                  </span>
                ))}
                <input className="chip !min-h-0 w-28 outline-none" placeholder="add id or @repo/id" onKeyDown={(e) => {
                  const raw = e.currentTarget.value.trim(); const v = raw.startsWith("@") ? raw : raw.toUpperCase();
                  if (e.key === "Enter" && v) { change({ ...draft, refines: [...draft.refines, v] }); e.currentTarget.value = ""; }
                }} />
              </div>
              {draft.summary && <><div className="text-xs font-semibold uppercase tracking-wider text-mute">Summary</div>{blocksEditor(summaryBlocks, (t) => change({ ...draft, summary: t }))}</>}
              {draft.body && <div className="mt-4 border-t border-line pt-2">{blocksEditor(bodyBlocks, (t) => change({ ...draft, body: t }))}</div>}
            </>
          )}
        </div>

        <aside className="shrink-0 overflow-y-auto border-t border-line p-3 text-sm lg:max-h-none lg:w-72 lg:border-l lg:border-t-0">
          <button className="mb-2 flex min-h-[44px] w-full items-center gap-2 text-left font-semibold lg:min-h-0 lg:cursor-default" onClick={() => setCheckOpen(!checkOpen)}>
            check_document
            <span className={`chip ${problems ? "!border-red-500 text-red-500" : "!border-emerald-500 text-emerald-600"}`}>{problems ? `${problems} unresolved` : "clean"}</span>
          </button>
          <ul className={`space-y-1 lg:block ${checkOpen ? "block max-h-40 overflow-y-auto" : "hidden"}`}>
            {refChecks.map((c, i) => (
              <li key={i} className="flex items-start gap-1.5 text-xs">
                {c.ok ? <Check size={14} className="mt-0.5 shrink-0 text-emerald-500" /> : <AlertTriangle size={14} className="mt-0.5 shrink-0 text-red-500" />}
                <span><span className="text-mute">{c.kind}</span> <span className="font-mono">{c.ref}</span>{!c.ok && " resolves to nothing"}</span>
              </li>
            ))}
          </ul>
          <p className="mt-3 hidden text-xs text-mute lg:block">Prototype: resolved against the fixture, not the service. Code names in <code>affects</code> are shown as resolved.</p>
        </aside>
      </div>

      {conflict && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-0 sm:items-center sm:p-6">
          <div className="max-h-full w-full max-w-3xl overflow-y-auto rounded-t-2xl bg-panel p-4 shadow-xl sm:rounded-2xl">
            <h3 className="mb-1 text-lg font-semibold">This file changed since you opened it</h3>
            <p className="mb-3 text-sm text-mute">The save was refused and nothing was written. Choose which text to keep.</p>
            <div className="grid gap-3 sm:grid-cols-2">
              <div><div className="mb-1 text-xs font-semibold uppercase text-mute">Your text</div>
                <pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-lg bg-line/30 p-2 font-mono text-xs">{draft.title}{"\n"}status: {draft.status}</pre></div>
              <div><div className="mb-1 text-xs font-semibold uppercase text-mute">On disk now</div>
                <pre className="max-h-56 overflow-auto whitespace-pre-wrap rounded-lg bg-amber-500/10 p-2 font-mono text-xs">{doc.title}{"\n"}status: {doc.status === "draft" ? "active" : "draft"}</pre></div>
            </div>
            <div className="mt-4 flex justify-end gap-2">
              <button className="btn" onClick={() => setConflict(false)}>Keep mine</button>
              <button className="btn btn-primary" onClick={() => { setDraft(doc); setConflict(false); }}>Take theirs</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
