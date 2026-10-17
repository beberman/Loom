import { useEffect, useMemo, useState } from "react";
import { Bot, FileText, Filter, LayoutGrid, List, Moon, Network, Plus, Sun } from "lucide-react";
import Sidebar, { EMPTY } from "./components/Sidebar";
import MapView from "./components/MapView";
import DocCard from "./components/DocCard";
import DocPanel from "./components/DocPanel";
import Agents from "./components/Agents";
import NewDoc from "./components/NewDoc";
import { DOCS, matches, widen } from "./data";
import type { AdapterMode, Doc, Filters } from "./types";

const MAP_LIMIT = 90;

export default function App() {
  const [docs, setDocs] = useState<Doc[]>(DOCS);
  const [filters, setFilters] = useState<Filters>({ ...EMPTY, types: ["REQ"], tag: "multi-user", widen: 2 });
  const [selected, setSelected] = useState<string | null>(null);
  const [view, setView] = useState<"map" | "list">(() => (window.matchMedia("(max-width: 767px)").matches ? "list" : "map"));
  const [showFilters, setShowFilters] = useState(false);
  const [showAgents, setShowAgents] = useState(false);
  const [showNew, setShowNew] = useState(false);
  const [mode, setMode] = useState<AdapterMode>("full");
  const [dark, setDark] = useState(() => window.matchMedia("(prefers-color-scheme: dark)").matches);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => { document.documentElement.classList.toggle("dark", dark); }, [dark]);
  useEffect(() => { if (!message) return; const t = setTimeout(() => setMessage(null), 3500); return () => clearTimeout(t); }, [message]);

  const { visible, matchedCount } = useMemo(() => {
    const matched = new Set(docs.filter((d) => matches(d, filters)).map((d) => d.id));
    const ids = filters.widen ? widen(docs, matched, filters.widen) : matched;
    return { visible: docs.filter((d) => ids.has(d.id)), matchedCount: matched.size };
  }, [docs, filters]);

  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    for (const d of docs) c[d.type] = (c[d.type] ?? 0) + 1;
    return c;
  }, [docs]);

  const doc = docs.find((d) => d.id === selected) ?? null;
  const tooBig = view === "map" && visible.length > MAP_LIMIT;

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center gap-1.5 border-b border-line bg-panel px-2 py-2 sm:gap-2 sm:px-3">
        <FileText size={20} className="text-accent" />
        <span className="font-semibold">Synoptik</span>
        <span className="hidden text-sm text-mute sm:inline">Documents</span>
        <span className="ml-1 hidden rounded bg-amber-500/20 px-1.5 py-0.5 text-[11px] font-medium text-amber-600 dark:text-amber-400 sm:inline">prototype · fixture data · nothing is written</span>
        <span className="flex-1" />
        <button className="btn md:hidden" onClick={() => setShowFilters(true)}><Filter size={16} /></button>
        <button className="btn btn-primary" onClick={() => setShowNew(true)}><Plus size={16} /><span className="hidden sm:inline">New</span></button>
        <button className="btn" onClick={() => setShowAgents(!showAgents)} aria-label="Agents"><Bot size={16} /><span className="hidden sm:inline">Agents</span></button>
        <button className="btn" onClick={() => setDark(!dark)} aria-label="Toggle theme">{dark ? <Sun size={16} /> : <Moon size={16} />}</button>
      </header>

      <div className="bg-amber-500/20 px-3 py-1 text-center text-[11px] font-medium text-amber-700 dark:text-amber-400 sm:hidden">prototype · fixture data · nothing is written</div>
      <div className="flex min-h-0 flex-1">
        <aside className="hidden w-72 shrink-0 border-r border-line bg-panel md:block">
          <Sidebar docs={docs} filters={filters} set={setFilters} counts={counts} />
        </aside>

        <main className="flex min-w-0 flex-1 flex-col gap-3 overflow-hidden p-3">
          <div className="flex flex-wrap items-center gap-2 text-sm">
            <span className="font-medium">{visible.length} documents</span>
            <span className="text-mute">{matchedCount} match{filters.widen ? `, ${visible.length - matchedCount} connected` : ""}</span>
            <span className="flex-1" />
            <div className="flex overflow-hidden rounded-lg border border-line">
              <button className={`btn !rounded-none !border-0 ${view === "map" ? "!bg-accent/15 text-accent" : ""}`} onClick={() => setView("map")}><Network size={16} /> Map</button>
              <button className={`btn !rounded-none !border-0 ${view === "list" ? "!bg-accent/15 text-accent" : ""}`} onClick={() => setView("list")}><List size={16} /> List</button>
            </div>
          </div>
          <div className="min-h-0 flex-1">
            {tooBig ? (
              <div className="flex h-full flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-line p-6 text-center">
                <LayoutGrid className="text-mute" />
                <p className="max-w-sm text-sm text-mute">{visible.length} documents is too many to draw as a map. Narrow the filters, or use a quick view.</p>
                <button className="btn" onClick={() => setView("list")}>Show as list</button>
              </div>
            ) : view === "map" ? (
              <MapView docs={visible} all={docs} selectedId={selected} onSelect={setSelected} />
            ) : (
              <div className="grid h-full grid-cols-[minmax(0,1fr)] content-start gap-2 overflow-y-auto sm:grid-cols-[repeat(2,minmax(0,1fr))] xl:grid-cols-[repeat(3,minmax(0,1fr))]">
                {visible.slice(0, 300).map((d) => <DocCard key={d.id} doc={d} selected={d.id === selected} onClick={() => setSelected(d.id)} />)}
              </div>
            )}
          </div>
        </main>

        {(doc || showAgents) && (
          <aside className="fixed inset-0 z-40 flex flex-col bg-panel md:static md:z-auto md:w-[min(46vw,640px)] md:border-l md:border-line">
            {showAgents && <div className={doc ? "h-1/3 border-b border-line" : "h-full"}><Agents mode={mode} setMode={setMode} onClose={() => setShowAgents(false)} toast={setMessage} /></div>}
            {doc && (
              <div className="min-h-0 flex-1">
                <DocPanel key={doc.id} doc={doc} all={docs} onClose={() => setSelected(null)} onSelect={setSelected} toast={setMessage}
                  onSave={(d) => setDocs(docs.map((x) => (x.id === d.id ? d : x)))} />
              </div>
            )}
          </aside>
        )}
      </div>

      {showFilters && (
        <div className="fixed inset-0 z-50 bg-panel md:hidden">
          <Sidebar docs={docs} filters={filters} set={setFilters} counts={counts} onClose={() => setShowFilters(false)} />
        </div>
      )}
      {showNew && <NewDoc all={docs} onClose={() => setShowNew(false)}
        onCreate={(d) => { setDocs([d, ...docs]); setShowNew(false); setSelected(d.id); setMessage(`Created ${d.id}. The real UI writes ${d.path}.`); }} />}
      {message && <div className="fixed bottom-4 left-1/2 z-[60] -translate-x-1/2 rounded-lg bg-ink px-4 py-2 text-sm text-bg shadow-lg">{message}</div>}
    </div>
  );
}
