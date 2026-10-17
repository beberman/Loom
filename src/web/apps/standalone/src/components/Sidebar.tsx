import { Search, X } from "lucide-react";
import { PRIORITIES, REPOS, STATUSES, TYPE_META, TYPE_ORDER, repoColor, tagCounts } from "../data";
import type { Doc, Filters } from "../types";

export const EMPTY: Filters = { repos: [], types: [], statuses: [], priority: "", tag: "", text: "", widen: 0 };

export default function Sidebar({
  docs, filters, set, counts, repoNames, onClose, recent, onOpen,
}: { docs: Doc[]; filters: Filters; set: (f: Filters) => void; counts: Record<string, number>; repoNames: string[]; onClose?: () => void; recent: Doc[]; onOpen: (key: string) => void }) {
  const toggle = (key: "repos" | "types" | "statuses", v: string) =>
    set({ ...filters, [key]: filters[key].includes(v) ? filters[key].filter((x) => x !== v) : [...filters[key], v] });
  const tags = tagCounts(docs).slice(0, 40);

  return (
    <div className="flex h-full flex-col gap-4 overflow-y-auto p-4">
      <div className="flex items-center justify-between md:hidden">
        <span className="font-semibold">Filters</span>
        <button className="btn" onClick={onClose} aria-label="Close filters"><X size={16} /></button>
      </div>

      <div className="relative">
        <Search size={15} className="pointer-events-none absolute left-3 top-3.5 text-mute md:top-3" />
        <input className="input pl-9" placeholder="Search id or title" value={filters.text}
          onChange={(e) => set({ ...filters, text: e.target.value })} />
      </div>

      <section>
        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">Repository</h3>
        <div className="flex flex-wrap gap-1.5">
          {repoNames.map((r) => {
            const on = filters.repos.includes(r), c = repoColor(r, REPOS.map((x) => x.name));
            return (
              <button key={r} onClick={() => toggle("repos", r)} className={`chip min-h-[44px] md:min-h-[32px] ${on ? "!border-transparent text-white" : ""}`}
                style={on ? { background: c } : undefined}>
                <span className="h-2 w-2 rounded-sm" style={{ background: on ? "#fff" : c }} /> {r}
              </button>
            );
          })}
        </div>
      </section>

      <section>
        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">Type</h3>
        <div className="flex flex-wrap gap-1.5">
          {TYPE_ORDER.map((t) => {
            const m = TYPE_META[t], on = filters.types.includes(t), Icon = m.icon;
            return (
              <button key={t} onClick={() => toggle("types", t)}
                className={`chip min-h-[44px] md:min-h-[32px] ${on ? "!border-transparent text-white" : ""}`}
                style={on ? { background: m.color } : undefined}>
                <Icon size={13} /> {m.label} <span className="opacity-70">{counts[t] ?? 0}</span>
              </button>
            );
          })}
        </div>
      </section>

      <section>
        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">Status</h3>
        <div className="flex flex-wrap gap-1.5">
          {STATUSES.map((s) => (
            <button key={s} onClick={() => toggle("statuses", s)}
              className={`chip min-h-[44px] md:min-h-[32px] ${filters.statuses.includes(s) ? "!border-accent !bg-accent/15 text-accent" : ""}`}>
              {s}
            </button>
          ))}
        </div>
      </section>

      <section className="grid grid-cols-2 gap-3">
        <label className="text-xs font-semibold uppercase tracking-wide text-mute">Priority
          <select className="input mt-1 font-normal normal-case" value={filters.priority}
            onChange={(e) => set({ ...filters, priority: e.target.value })}>
            <option value="">any</option>
            {PRIORITIES.map((p) => <option key={p}>{p}</option>)}
          </select>
        </label>
        <label className="text-xs font-semibold uppercase tracking-wide text-mute">Tag
          <select className="input mt-1 font-normal normal-case" value={filters.tag}
            onChange={(e) => set({ ...filters, tag: e.target.value })}>
            <option value="">any</option>
            {tags.map(([t, n]) => <option key={t} value={t}>{t} ({n})</option>)}
          </select>
        </label>
      </section>

      <section>
        <h3 className="mb-1 text-xs font-semibold uppercase tracking-wide text-mute">
          Include connected documents: {filters.widen === 0 ? "off" : `${filters.widen} link${filters.widen > 1 ? "s" : ""}`}
        </h3>
        <input type="range" min={0} max={3} value={filters.widen} className="h-11 w-full accent-[rgb(var(--accent))] md:h-6"
          onChange={(e) => set({ ...filters, widen: Number(e.target.value) })} />
        <p className="text-xs text-mute">Adds what refines the matches (designs, then plans) and what the matches refine, one direction at a time.</p>
      </section>

      {recent.length > 0 && (
        <section>
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">Recently opened</h3>
          <div className="flex flex-col gap-1.5">
            {recent.map((d) => (
              <button key={`${d.repo}/${d.id}`} className="btn justify-start" onClick={() => onOpen(`${d.repo}/${d.id}`)}>
                <span className="font-mono text-xs">{d.id}</span><span className="truncate">{d.title}</span>
              </button>
            ))}
          </div>
        </section>
      )}

      <section>
        <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-mute">Quick views</h3>
        <div className="flex flex-col gap-1.5">
          <button className="btn justify-start" onClick={() => set({ ...EMPTY, types: ["REQ"], tag: "multi-user", widen: 2 })}>
            Multi-user requirements + 2 links
          </button>
          <button className="btn justify-start" onClick={() => set({ ...EMPTY, types: ["REQ"], statuses: ["draft"], widen: 1 })}>
            Draft requirements + 1 link
          </button>
          <button className="btn justify-start" onClick={() => set({ ...EMPTY, types: ["BUG"], statuses: ["open"] })}>
            Open bugs
          </button>
          <button className="btn justify-start" onClick={() => set(EMPTY)}>Clear filters</button>
        </div>
      </section>
    </div>
  );
}
