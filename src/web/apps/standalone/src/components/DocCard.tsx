import { REPOS, TYPE_META, repoColor, shortTitle } from "../data";
import type { Doc } from "../types";

const STATUS_DOT: Record<string, string> = {
  draft: "bg-amber-400", open: "bg-amber-400", active: "bg-sky-500",
  implemented: "bg-emerald-500", final: "bg-emerald-500", closed: "bg-emerald-500", accepted: "bg-emerald-500",
  partial: "bg-orange-500", withdrawn: "bg-slate-400", superseded: "bg-slate-400",
};

export function TypeIcon({ type, size = 36 }: { type: string; size?: number }) {
  const m = TYPE_META[type];
  const Icon = m.icon;
  return (
    <span
      className="inline-flex shrink-0 items-center justify-center rounded-lg"
      style={{ width: size, height: size, background: m.color + "22", color: m.color }}
      title={m.label}
    >
      <Icon size={size * 0.55} strokeWidth={2} />
    </span>
  );
}

export function RepoPill({ name }: { name: string }) {
  const c = repoColor(name, REPOS.map((r) => r.name));
  return <span className="ml-auto truncate rounded px-1.5 text-[10px] font-semibold" style={{ background: c + "22", color: c }}>{name}</span>;
}

export function StatusDot({ status }: { status: string }) {
  return <span className={`inline-block h-2 w-2 rounded-full ${STATUS_DOT[status] ?? "bg-slate-400"}`} title={status} />;
}

export default function DocCard({
  doc, selected, onClick, style, dim, showRepo,
}: { doc: Doc; selected?: boolean; onClick: () => void; style?: React.CSSProperties; dim?: boolean; showRepo?: boolean }) {
  return (
    <button
      onClick={onClick}
      style={style}
      title={doc.title}
      className={`flex min-h-[44px] w-full items-center gap-2.5 rounded-xl border bg-panel p-2 text-left shadow-sm transition hover:border-accent ${
        selected ? "border-accent ring-2 ring-accent/40" : "border-line"
      } ${dim ? "opacity-50" : ""}`}
    >
      <TypeIcon type={doc.type} />
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-1.5 whitespace-nowrap font-mono text-[11px] text-mute">
          {doc.id}
          <StatusDot status={doc.status} />
          {!showRepo && <span>{doc.status}</span>}
          {doc.isNew && <span className="rounded bg-accent/15 px-1 text-accent">new</span>}
          {showRepo && <RepoPill name={doc.repo} />}
        </span>
        <span className="block truncate text-sm font-medium">{shortTitle(doc.title)}</span>
      </span>
    </button>
  );
}
