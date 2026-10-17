import { useEffect, useMemo, useState } from "react";
import { Bot, FileText, Filter, GitBranch, LayoutGrid, List, Moon, Network, Plus, Sun } from "lucide-react";
import Sidebar, { EMPTY } from "./components/Sidebar";
import MapView from "./components/MapView";
import DocCard from "./components/DocCard";
import DocPanel from "./components/DocPanel";
import Agents from "./components/Agents";
import NewDoc from "./components/NewDoc";
import Workspace from "./components/Workspace";
import { DOCS, REPOS, key, matches, widen } from "./data";
import type { AdapterMode, Doc, Filters, Repo } from "./types";

const MAP_LIMIT = 90;
type Panel = "agents" | "workspace" | null;

function loadUi(): { filters?: Filters; view?: "map" | "list"; dark?: boolean; selected?: string | null; recent?: string[] } {
  try { return JSON.parse(localStorage.getItem("synoptik-ui") ?? "{}"); } catch { return {}; }
}

export default function App() {
  const [docs, setDocs] = useState<Doc[]>(DOCS);
  // Stands in for ~/.synoptik/web.json (DES-0057 D16); the real store is on the Node server.
  const [repos, setRepos] = useState<Repo[]>(() => {
    try {
      const saved = JSON.parse(localStorage.getItem("synoptik-workspace") ?? "null") as Repo[] | null;
      if (Array.isArray(saved)) return saved.map((r) => ({ ...r, state: r.state === "paused" ? "paused" : "ready" }));
    } catch { /* storage unavailable or unparsable: start from the default */ }
    return REPOS;
  });
  // Stands in for ~/.synoptik/ui-state.json (DES-0057 D17): filters, view, theme,
  // the open document and the documents last opened.
  const saved = useMemo(loadUi, []);
  const [filters, setFilters] = useState<Filters>(saved.filters ?? { ...EMPTY, types: ["REQ"], tag: "multi-user", widen: 2 });
  const [selected, setSelected] = useState<string | null>(saved.selected ?? null);
  const [recent, setRecent] = useState<string[]>(saved.recent ?? []);
  const [view, setView] = useState<"map" | "list">(saved.view ?? (window.matchMedia("(max-width: 767px)").matches ? "list" : "map"));
  const [showFilters, setShowFilters] = useState(false);
  const [panel, setPanel] = useState<Panel>(null);
  const [showNew, setShowNew] = useState(false);
  const [mode, setMode] = useState<AdapterMode>("full");
  const [dark, setDark] = useState(() => saved.dark ?? window.matchMedia("(prefers-color-scheme: dark)").matches);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => { document.documentElement.classList.toggle("dark", dark); }, [dark]);
  useEffect(() => { if (!message) return; const t = setTimeout(() => setMessage(null), 3500); return () => clearTimeout(t); }, [message]);

  // The workspace is the set of folders the service watches. A removed folder's
  // documents are gone from every view; a paused one keeps its index.
  useEffect(() => {
    try { localStorage.setItem("synoptik-workspace", JSON.stringify(repos)); } catch { /* ignore */ }
  }, [repos]);
  useEffect(() => {
    try { localStorage.setItem("synoptik-ui", JSON.stringify({ filters, view, dark, selected, recent })); } catch { /* ignore */ }
  }, [filters, view, dark, selected, recent]);
  useEffect(() => { if (selected) setRecent((r) => [selected, ...r.filter((k) => k !== selected)].slice(0, 8)); }, [selected]);
  const inWorkspace = useMemo(() => docs.filter((d) => repos.some((r) => r.name === d.repo)), [docs, repos]);
  const repoNames = repos.map((r) => r.name);

  const { visible, matchedCount } = useMemo(() => {
    const matched = new Set(inWorkspace.filter((d) => matches(d, filters)).map(key));
    const ids = filters.widen ? widen(inWorkspace, matched, filters.widen) : matched;
    return { visible: inWorkspace.filter((d) => ids.has(key(d))), matchedCount: matched.size };
  }, [inWorkspace, filters]);

  const counts = useMemo(() => {
    const c: Record<string, number> = {};
    for (const d of inWorkspace) { c[d.type] = (c[d.type] ?? 0) + 1; c[d.repo] = (c[d.repo] ?? 0) + 1; }
    return c;
  }, [inWorkspace]);

  const doc = inWorkspace.find((d) => key(d) === selected) ?? null;
  const tooBig = view === "map" && visible.length > MAP_LIMIT;
  const multi = new Set(visible.map((d) => d.repo)).size > 1;
  const sidePanel = doc || panel;

  const sidebar = (onClose?: () => void) => (
    <Sidebar docs={inWorkspace} filters={filters} set={setFilters} counts={counts} repoNames={repoNames} onClose={onClose}
      recent={recent.map((k) => inWorkspace.find((d) => key(d) === k)).filter((d): d is Doc => !!d)} onOpen={setSelected} />
  );

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center gap-1.5 border-b border-line bg-panel px-2 py-2 sm:gap-2 sm:px-3">
        <FileText size={20} className="text-accent" />
        <span className="font-semibold">Synoptik</span>
        <span className="ml-1 hidden rounded bg-amber-500/20 px-1.5 py-0.5 text-[11px] font-medium text-amber-600 dark:text-amber-400 sm:inline">prototype · fixture data · nothing is written</span>
        <span className="flex-1" />
        <button className="btn md:hidden" onClick={() => setShowFilters(true)} aria-label="Filters"><Filter size={16} /></button>
        <button className="btn btn-primary" onClick={() => setShowNew(true)}><Plus size={16} /><span className="hidden sm:inline">New</span></button>
        <button className={`btn ${panel === "workspace" ? "!border-accent text-accent" : ""}`} onClick={() => setPanel(panel === "workspace" ? null : "workspace")} aria-label="Workspace">
          <GitBranch size={16} /><span className="hidden sm:inline">Workspace · {repos.length}</span>
        </button>
        <button className={`btn ${panel === "agents" ? "!border-accent text-accent" : ""}`} onClick={() => setPanel(panel === "agents" ? null : "agents")} aria-label="Agents">
          <Bot size={16} /><span className="hidden sm:inline">Agents</span>
        </button>
        <button className="btn" onClick={() => setDark(!dark)} aria-label="Toggle theme">{dark ? <Sun size={16} /> : <Moon size={16} />}</button>
      </header>
      <div className="bg-amber-500/20 px-3 py-1 text-center text-[11px] font-medium text-amber-700 dark:text-amber-400 sm:hidden">prototype · fixture data · nothing is written</div>

      <div className="flex min-h-0 flex-1">
        <aside className="hidden w-72 shrink-0 border-r border-line bg-panel md:block">{sidebar()}</aside>

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
            {repos.length === 0 ? (
              <div className="flex h-full flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-line p-6 text-center">
                <GitBranch className="text-mute" />
                <p className="max-w-sm text-sm text-mute">The workspace has no folders. Add one to see its documents.</p>
                <button className="btn btn-primary" onClick={() => setPanel("workspace")}>Open workspace</button>
              </div>
            ) : tooBig ? (
              <div className="flex h-full flex-col items-center justify-center gap-3 rounded-xl border border-dashed border-line p-6 text-center">
                <LayoutGrid className="text-mute" />
                <p className="max-w-sm text-sm text-mute">{visible.length} documents is too many to draw as a map. Narrow the filters, or use a quick view.</p>
                <button className="btn" onClick={() => setView("list")}>Show as list</button>
              </div>
            ) : view === "map" ? (
              <MapView docs={visible} all={inWorkspace} selectedId={selected} onSelect={setSelected} />
            ) : (
              <div className="grid h-full grid-cols-[minmax(0,1fr)] content-start gap-2 overflow-y-auto sm:grid-cols-[repeat(2,minmax(0,1fr))] xl:grid-cols-[repeat(3,minmax(0,1fr))]">
                {visible.slice(0, 300).map((d) => <DocCard key={key(d)} doc={d} showRepo={multi} selected={key(d) === selected} onClick={() => setSelected(key(d))} />)}
              </div>
            )}
          </div>
        </main>

        {sidePanel && (
          <aside className="fixed inset-0 z-40 flex flex-col bg-panel md:static md:z-auto md:w-[min(46vw,640px)] md:border-l md:border-line">
            {panel && (
              <div className={doc ? "h-1/3 border-b border-line" : "h-full"}>
                {panel === "agents"
                  ? <Agents mode={mode} setMode={setMode} onClose={() => setPanel(null)} toast={setMessage} />
                  : <Workspace repos={repos} setRepos={setRepos} counts={counts} onClose={() => setPanel(null)} toast={setMessage}
                      onIndexed={(name) => setTimeout(() => setRepos((cur) => cur.map((r) => r.name === name ? { ...r, state: "ready", commit: "a1b2c3d" } : r)), 1800)} />}
              </div>
            )}
            {doc && (
              <div className="min-h-0 flex-1">
                <DocPanel key={key(doc)} doc={doc} all={inWorkspace} onClose={() => setSelected(null)} onSelect={setSelected} toast={setMessage}
                  onSave={(d) => setDocs(docs.map((x) => (key(x) === key(d) ? d : x)))} />
              </div>
            )}
          </aside>
        )}
      </div>

      {showFilters && <div className="fixed inset-0 z-50 bg-panel md:hidden">{sidebar(() => setShowFilters(false))}</div>}
      {showNew && <NewDoc all={inWorkspace} repoNames={repoNames} onClose={() => setShowNew(false)}
        onCreate={(d) => { setDocs([d, ...docs]); setShowNew(false); setSelected(key(d)); setMessage(`Created ${d.id} in ${d.repo}. The real UI writes ${d.path}.`); }} />}
      {message && <div className="fixed bottom-4 left-1/2 z-[60] -translate-x-1/2 rounded-lg bg-ink px-4 py-2 text-sm text-bg shadow-lg">{message}</div>}
    </div>
  );
}
