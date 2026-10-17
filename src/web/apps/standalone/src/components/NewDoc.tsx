import { useState } from "react";
import { X } from "lucide-react";
import { TYPE_META, nextId, shortTitle, todayIso } from "../data";
import { TypeIcon } from "./DocCard";
import type { Doc } from "../types";

const TEMPLATE: Record<string, { status: string; summary: string; body: string }> = {
  REQ: { status: "draft", summary: "What is wanted, in two sentences a reader can check.",
    body: "WHAT IS WANTED\n\nR1  \n\nACCEPTANCE\n\nWhat a reviewer does to see it met.\n\nOPEN QUESTIONS\n\n- " },
  BUG: { status: "open", summary: "What happens, and what should happen.",
    body: "WHAT HAPPENS\n\nREPRODUCTION\n\nEXPECTED\n\nCAUSE" },
};

export default function NewDoc({
  all, onCreate, onClose,
}: { all: Doc[]; onCreate: (d: Doc) => void; onClose: () => void }) {
  const [type, setType] = useState<"REQ" | "BUG">("REQ");
  const [title, setTitle] = useState("");
  const [refines, setRefines] = useState<string[]>([]);
  const [q, setQ] = useState("");
  const id = nextId(all, type);
  const options = q ? all.filter((d) => (d.id + d.title).toLowerCase().includes(q.toLowerCase())).slice(0, 6) : [];

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 sm:items-center sm:p-6">
      <div className="max-h-full w-full max-w-lg overflow-y-auto rounded-t-2xl bg-panel p-4 shadow-xl sm:rounded-2xl">
        <div className="mb-3 flex items-center justify-between">
          <h3 className="text-lg font-semibold">New document</h3>
          <button className="btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
        </div>
        <div className="mb-3 grid grid-cols-2 gap-2">
          {(["REQ", "BUG"] as const).map((t) => (
            <button key={t} onClick={() => setType(t)} className={`btn !justify-start gap-2 ${type === t ? "!border-accent ring-2 ring-accent/30" : ""}`}>
              <TypeIcon type={t} size={26} /> {TYPE_META[t].label}
            </button>
          ))}
        </div>
        <p className="mb-3 text-xs text-mute">Only requirements and bugs are created here. Designs, plans, decisions and the rest are drafted by agents and edited here.</p>
        <div className="mb-1 font-mono text-xs text-mute">Next free id: {id}</div>
        <input className="input mb-3" placeholder="Title, as a sentence a reader can check" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus />
        <div className="mb-1 text-xs text-mute">Refines (optional)</div>
        <div className="mb-2 flex flex-wrap gap-1.5">
          {refines.map((r) => <span key={r} className="chip">{r}<button onClick={() => setRefines(refines.filter((x) => x !== r))} aria-label={`Remove ${r}`}><X size={12} /></button></span>)}
        </div>
        <input className="input" placeholder="Search a document to refine" value={q} onChange={(e) => setQ(e.target.value)} />
        {options.length > 0 && (
          <ul className="mt-1 overflow-hidden rounded-lg border border-line">
            {options.map((d) => (
              <li key={d.id}><button className="flex min-h-[44px] w-full items-center gap-2 px-2 text-left text-sm hover:bg-line/40"
                onClick={() => { setRefines([...new Set([...refines, d.id])]); setQ(""); }}>
                <TypeIcon type={d.type} size={24} /><span className="font-mono text-xs">{d.id}</span><span className="truncate">{shortTitle(d.title)}</span></button></li>
            ))}
          </ul>
        )}
        <div className="mt-4 flex justify-end gap-2">
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" disabled={!title.trim()} onClick={() => {
            const t = TEMPLATE[type];
            onCreate({ id, type, title: title.trim(), status: t.status, priority: "", date: todayIso(), tags: [], refines,
              affects: [], summary: t.summary, body: t.body, path: `docs/${type === "REQ" ? "requirements" : "bugs"}/${id}.yaml`, isNew: true });
          }}>Create {id}</button>
        </div>
      </div>
    </div>
  );
}
