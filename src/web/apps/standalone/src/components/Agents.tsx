import { useEffect, useState } from "react";
import { Bot, Play, Square, X, Check, Ban } from "lucide-react";
import type { AdapterMode, AgentStatus, Session } from "../types";

const COLOR: Record<AgentStatus, string> = {
  working: "bg-sky-500", "waiting-input": "bg-amber-500", "waiting-approval": "bg-orange-500",
  idle: "bg-slate-400", finished: "bg-emerald-500", failed: "bg-red-500", unknown: "bg-slate-300",
};

const SEED: Session[] = [
  { id: "s1", task: "Draft DES for the editor library spike", repository: "Synoptik", status: "working", since: "4 min" },
  { id: "s2", task: "Implement write-document and its conflict test", repository: "Synoptik", status: "waiting-approval", since: "1 min" },
  { id: "s3", task: "Answer review notes on REQ-0080", repository: "Synoptik", status: "waiting-input", since: "12 min" },
  { id: "s4", task: "Index game-server docs", repository: "game-server", status: "idle", since: "40 min" },
  { id: "s5", task: "Plan the proxy tests", repository: "Synoptik", status: "finished", since: "1 h" },
  { id: "s6", task: "Fix BUG-0083 regression", repository: "Synoptik", status: "failed", since: "2 h" },
  { id: "s7", task: "Session started outside this tool", repository: "front-end", status: "unknown", since: "—" },
];

export default function Agents({
  mode, setMode, onClose, toast,
}: { mode: AdapterMode; setMode: (m: AdapterMode) => void; onClose: () => void; toast: (m: string) => void }) {
  const [sessions, setSessions] = useState<Session[]>(SEED);
  const [task, setTask] = useState("");
  const [repo, setRepo] = useState("Synoptik");

  // Stands in for subscribe(): the working session asks for approval after a few seconds.
  useEffect(() => {
    const t = setInterval(() => setSessions((s) => s.map((x) => x.id === "s1" ? { ...x, status: x.status === "working" ? "waiting-approval" : "working" } : x)), 6000);
    return () => clearInterval(t);
  }, []);

  const full = mode === "full";
  return (
    <div className="flex h-full flex-col bg-panel">
      <div className="flex items-center gap-2 border-b border-line p-3">
        <Bot size={18} /> <span className="font-semibold">Agents</span>
        <select className="input ml-auto !w-auto" value={mode} onChange={(e) => setMode(e.target.value as AdapterMode)} aria-label="Adapter capabilities">
          <option value="full">Adapter: full control</option>
          <option value="list-only">Adapter: list only</option>
          <option value="none">No adapter</option>
        </select>
        <button className="btn" onClick={onClose} aria-label="Close agents"><X size={16} /></button>
      </div>

      {mode === "none" ? (
        <p className="p-4 text-sm text-mute">No agent adapter is configured. Documents, relationships and editing work without one. Choose an adapter above to see what each capability level offers.</p>
      ) : (
        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-3">
          {full && (
            <form className="space-y-2 rounded-xl border border-line p-3" onSubmit={(e) => {
              e.preventDefault();
              if (!task.trim()) return;
              setSessions([{ id: "n" + Date.now(), task, repository: repo, status: "working", since: "now" }, ...sessions]);
              setTask(""); toast("Launched (prototype: no process started).");
            }}>
              <div className="text-xs font-semibold uppercase tracking-wide text-mute">Launch</div>
              <select className="input" value={repo} onChange={(e) => setRepo(e.target.value)}>
                <option>Synoptik</option><option>game-server</option><option>front-end</option>
              </select>
              <textarea className="input !min-h-[72px] py-2" placeholder="Task, e.g. Draft the plan for REQ-0081" value={task} onChange={(e) => setTask(e.target.value)} />
              <button className="btn btn-primary w-full" type="submit"><Play size={16} /> Launch agent</button>
            </form>
          )}
          {sessions.map((s) => (
            <div key={s.id} className="rounded-xl border border-line p-3">
              <div className="flex items-center gap-2 text-xs">
                <span className={`h-2.5 w-2.5 rounded-full ${COLOR[s.status]}`} />
                <span className="font-semibold">{s.status}</span>
                <span className="text-mute">· {s.repository} · {s.since}</span>
              </div>
              <div className="mt-1 text-sm">{s.task}</div>
              {full && (
                <div className="mt-2 flex flex-wrap gap-2">
                  {s.status === "waiting-approval" && (<>
                    <button className="btn" onClick={() => { setSessions(sessions.map((x) => x.id === s.id ? { ...x, status: "working" } : x)); toast("Approved"); }}><Check size={16} /> Approve</button>
                    <button className="btn" onClick={() => toast("Denied")}><Ban size={16} /> Deny</button>
                  </>)}
                  {["working", "waiting-input", "waiting-approval", "idle"].includes(s.status) && (
                    <button className="btn" onClick={() => { setSessions(sessions.map((x) => x.id === s.id ? { ...x, status: "finished" } : x)); toast("Stopped"); }}><Square size={16} /> Stop</button>
                  )}
                </div>
              )}
            </div>
          ))}
          {!full && <p className="text-xs text-mute">This adapter lists sessions and reports status. It reports no launch, stop or approval capability, so those controls are not shown.</p>}
        </div>
      )}
    </div>
  );
}
