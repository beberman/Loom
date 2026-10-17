import { useState } from "react";
import { Folder, FolderPlus, GitBranch, Pause, Play, Trash2, X, RefreshCw } from "lucide-react";
import { REPOS, repoColor } from "../data";
import type { Repo } from "../types";

// Folders the Node server would offer: the configured roots, one level down.
// `git` is whether the folder is a git repository; the real server checks.
const CANDIDATES = [
  { path: "~/lisp/cl-dbi", git: true },
  { path: "~/lisp/cl-mysql", git: true },
  { path: "~/lisp/datascience", git: true },
  { path: "~/lisp/linear-algebra", git: true },
  { path: "~/lisp/numerical-utilities", git: true },
  { path: "~/github/lfia-accounting", git: true },
  { path: "~/lisp/#g#", git: false },
];

const STATE_STYLE: Record<Repo["state"], string> = {
  ready: "bg-emerald-500", indexing: "bg-amber-500 animate-pulse", paused: "bg-slate-400",
};

export default function Workspace({
  repos, setRepos, onIndexed, counts, onClose, toast,
}: { repos: Repo[]; setRepos: (r: Repo[]) => void; onIndexed: (name: string) => void; counts: Record<string, number>; onClose: () => void; toast: (m: string) => void }) {
  const [picking, setPicking] = useState(false);
  const [confirm, setConfirm] = useState<string | null>(null);
  const names = REPOS.map((r) => r.name);
  const taken = new Set(repos.map((r) => r.path));

  const add = (path: string) => {
    const name = path.split("/").pop()!;
    setRepos([...repos, { name, path, commit: "", documents: 0, state: "indexing" }]);
    setPicking(false);
    toast(`watch ${path}: indexing…`);
    onIndexed(name);
  };

  return (
    <div className="flex h-full flex-col bg-panel">
      <div className="flex items-center gap-2 border-b border-line p-3">
        <GitBranch size={18} /> <span className="font-semibold">Workspace</span>
        <span className="text-xs text-mute">{repos.length} folders</span>
        <button className="btn btn-primary ml-auto" onClick={() => setPicking(true)}><FolderPlus size={16} /> Add folder</button>
        <button className="btn" onClick={onClose} aria-label="Close workspace"><X size={16} /></button>
      </div>

      <ul className="min-h-0 flex-1 space-y-2 overflow-y-auto p-3">
        {repos.map((r) => (
          <li key={r.name} className="rounded-xl border border-line p-3">
            <div className="flex items-center gap-2">
              <span className="h-3 w-3 rounded" style={{ background: repoColor(r.name, names) }} />
              <span className="font-semibold">{r.name}</span>
              <span className={`ml-1 h-2 w-2 rounded-full ${STATE_STYLE[r.state]}`} />
              <span className="text-xs text-mute">{r.state}</span>
            </div>
            <div className="mt-1 font-mono text-xs text-mute">{r.path}</div>
            <div className="mt-1 text-xs text-mute">
              {r.state === "indexing" ? "Indexing…" : `${counts[r.name] ?? r.documents} documents · commit ${r.commit || "—"} · index current with the tree`}
            </div>
            <div className="mt-2 flex flex-wrap gap-2">
              <button className="btn" disabled={r.state === "indexing"}
                onClick={() => { setRepos(repos.map((x) => x.name === r.name ? { ...x, state: x.state === "paused" ? "ready" : "paused" } : x)); toast(`${r.state === "paused" ? "watch" : "pause"} ${r.name}`); }}>
                {r.state === "paused" ? <><Play size={16} /> Resume</> : <><Pause size={16} /> Pause</>}
              </button>
              <button className="btn" onClick={() => toast(`reindex ${r.name}`)} disabled={r.state !== "ready"}><RefreshCw size={16} /> Reindex</button>
              <button className="btn" onClick={() => setConfirm(r.name)}><Trash2 size={16} /> Remove</button>
            </div>
          </li>
        ))}
        {repos.length === 0 && <p className="text-sm text-mute">No folders. Add one to see its documents.</p>}
      </ul>

      {picking && (
        <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/50 sm:items-center sm:p-6">
          <div className="max-h-full w-full max-w-md overflow-y-auto rounded-t-2xl bg-panel p-4 shadow-xl sm:rounded-2xl">
            <div className="mb-2 flex items-center justify-between"><h3 className="text-lg font-semibold">Add folder</h3>
              <button className="btn" onClick={() => setPicking(false)} aria-label="Close"><X size={16} /></button></div>
            <p className="mb-3 text-xs text-mute">The server lists folders under its configured roots (<code>~/lisp</code>, <code>~/github</code>) and accepts only git repositories.</p>
            <ul className="space-y-1">
              {CANDIDATES.map((c) => {
                const off = !c.git || taken.has(c.path);
                return (
                  <li key={c.path}>
                    <button disabled={off} onClick={() => add(c.path)} className="btn w-full !justify-start disabled:!opacity-50">
                      <Folder size={16} /> <span className="font-mono text-xs">{c.path}</span>
                      <span className="ml-auto text-xs text-mute">{taken.has(c.path) ? "already added" : !c.git ? "not a git repository" : ""}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          </div>
        </div>
      )}

      {confirm && (
        <div className="fixed inset-0 z-[55] flex items-end justify-center bg-black/50 sm:items-center sm:p-6">
          <div className="w-full max-w-md rounded-t-2xl bg-panel p-4 shadow-xl sm:rounded-2xl">
            <h3 className="mb-1 text-lg font-semibold">Remove {confirm} from the workspace?</h3>
            <p className="mb-4 text-sm text-mute">Synoptik stops watching it and drops its index. Nothing on disk is deleted, and adding the folder again rebuilds the index.</p>
            <div className="flex justify-end gap-2">
              <button className="btn" onClick={() => setConfirm(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={() => { setRepos(repos.filter((r) => r.name !== confirm)); toast(`unwatch ${confirm}`); setConfirm(null); }}>Remove</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
