import { useMemo, useState } from "react";
import { ArrowRight, X, ListChecks } from "lucide-react";
import Editor from "./Editor";
import DocCard, { TypeIcon } from "./DocCard";
import { TYPE_META, indexById } from "../data";
import type { Doc } from "../types";

export default function DocPanel({
  doc, all, onClose, onSelect, onSave, toast,
}: { doc: Doc; all: Doc[]; onClose: () => void; onSelect: (id: string) => void; onSave: (d: Doc) => void; toast: (m: string) => void }) {
  const [tab, setTab] = useState<"edit" | "relations">("edit");
  const [dry, setDry] = useState(false);
  const byId = useMemo(() => indexById(all), [all]);
  const refinedBy = all.filter((d) => d.refines.includes(doc.id));

  const dryRun = [
    `${doc.id}  status ${doc.status} -> final`,
    ...doc.refines.filter((r) => byId.has(r)).map((r) => `${r}  status ${byId.get(r)!.status} -> implemented   (needs a verdict)`),
    "",
    "Dry run. Nothing is written. Give each document its verdict to apply.",
  ].join("\n");

  return (
    <div className="flex h-full flex-col bg-panel">
      <div className="flex items-start gap-3 border-b border-line p-3">
        <TypeIcon type={doc.type} size={40} />
        <div className="min-w-0 flex-1">
          <div className="font-mono text-xs text-mute">{doc.id} · {TYPE_META[doc.type].label} · {doc.path}</div>
          <div className="truncate text-sm font-semibold" title={doc.title}>{doc.title}</div>
        </div>
        <button className="btn" onClick={onClose} aria-label="Close"><X size={16} /></button>
      </div>
      <div className="flex gap-1 border-b border-line px-2 pt-2">
        {(["edit", "relations"] as const).map((t) => (
          <button key={t} onClick={() => setTab(t)}
            className={`min-h-[44px] rounded-t-lg px-4 text-sm font-medium md:min-h-[36px] ${tab === t ? "border-b-2 border-accent text-accent" : "text-mute"}`}>
            {t === "edit" ? "Edit" : "Relationships"}
          </button>
        ))}
        {doc.type === "PLAN" && <button className="btn ml-auto mb-1" onClick={() => setDry(true)}><ListChecks size={16} /> Complete…</button>}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {tab === "edit" ? (
          <Editor doc={doc} all={all} onSave={onSave} toast={toast}
            onStatus={(s) => toast(`In the real UI this runs set-status ${doc.id} ${s} and files the document.`)} />
        ) : (
          <div className="space-y-5 p-4">
            <Group title="Refines" empty="Refines nothing.">
              {doc.refines.map((r) => byId.has(r)
                ? <DocCard key={r} doc={byId.get(r)!} onClick={() => onSelect(r)} />
                : <div key={r} className="rounded-xl border border-dashed border-red-500 p-2 text-sm text-red-500">{r} — unresolved: no document has this id</div>)}
            </Group>
            <Group title={`Refined by (${refinedBy.length})`} empty="Nothing refines it.">
              {refinedBy.map((d) => <DocCard key={d.id} doc={d} onClick={() => onSelect(d.id)} />)}
            </Group>
            <Group title="Affects (code)" empty="Names no code.">
              {doc.affects.map((a) => <div key={a} className="flex items-center gap-2 rounded-lg bg-line/30 px-2 py-1.5 font-mono text-xs"><ArrowRight size={12} />{a}</div>)}
            </Group>
          </div>
        )}
      </div>

      {dry && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 sm:items-center sm:p-6">
          <div className="w-full max-w-xl rounded-t-2xl bg-panel p-4 shadow-xl sm:rounded-2xl">
            <h3 className="mb-2 text-lg font-semibold">complete {doc.id} — dry run</h3>
            <pre className="max-h-72 overflow-auto whitespace-pre-wrap rounded-lg bg-line/30 p-3 font-mono text-xs">{dryRun}</pre>
            <div className="mt-3 flex justify-end"><button className="btn btn-primary" onClick={() => setDry(false)}>Close</button></div>
          </div>
        </div>
      )}
    </div>
  );
}

function Group({ title, empty, children }: { title: string; empty: string; children: React.ReactNode[] }) {
  return (
    <section>
      <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">{title}</h4>
      <div className="space-y-1.5">{children.length ? children : <p className="text-sm text-mute">{empty}</p>}</div>
    </section>
  );
}
