import { useMemo } from "react";
import { AlertTriangle } from "lucide-react";
import DocCard from "./DocCard";
import { TYPE_META, TYPE_ORDER, edgesOf } from "../data";
import type { Doc } from "../types";

const W = 232, H = 56, GX = 96, GY = 14, HEAD = 34;

export default function MapView({
  docs, all, selectedId, onSelect,
}: { docs: Doc[]; all: Doc[]; selectedId: string | null; onSelect: (id: string) => void }) {
  const { cols, pos, width, height } = useMemo(() => {
    const present = TYPE_ORDER.filter((t) => docs.some((d) => d.type === t));
    const cols = present.map((t) => ({ type: t, docs: docs.filter((d) => d.type === t) }));
    const pos = new Map<string, { x: number; y: number }>();
    let height = 0;
    cols.forEach((c, ci) =>
      c.docs.forEach((d, ri) => {
        pos.set(d.id, { x: ci * (W + GX), y: HEAD + ri * (H + GY) });
        height = Math.max(height, HEAD + (ri + 1) * (H + GY));
      }),
    );
    return { cols, pos, width: cols.length * (W + GX) - GX, height };
  }, [docs]);

  const edges = useMemo(() => edgesOf(docs, all).filter((e) => pos.has(e.from)), [docs, all, pos]);
  const unresolved = new Set(edges.filter((e) => !e.resolved).map((e) => e.from));

  const line = (a: { x: number; y: number }, b: { x: number; y: number }) => {
    const leftToRight = a.x < b.x;
    const same = a.x === b.x;
    const x1 = same ? a.x + W : leftToRight ? a.x + W : a.x;
    const x2 = same ? b.x + W : leftToRight ? b.x : b.x + W;
    const y1 = a.y + H / 2, y2 = b.y + H / 2;
    const dx = same ? 40 : (x2 - x1) / 2;
    return `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`;
  };

  return (
    <div className="h-full overflow-auto rounded-xl border border-line bg-panel/60 p-4">
      <div className="relative" style={{ width, height: height + 8 }}>
        <svg className="pointer-events-none absolute inset-0" width={width} height={height + 8}>
          <defs>
            <marker id="arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
              <path d="M0,0 L8,4 L0,8 z" fill="rgb(var(--mute))" />
            </marker>
          </defs>
          {edges.filter((e) => e.resolved && pos.has(e.to)).map((e) => {
            const hot = selectedId === e.from || selectedId === e.to;
            return (
              <path
                key={e.from + e.to}
                d={line(pos.get(e.from)!, pos.get(e.to)!)}
                fill="none"
                stroke={hot ? "rgb(var(--accent))" : "rgb(var(--mute))"}
                strokeOpacity={hot ? 1 : selectedId ? 0.12 : 0.28}
                strokeWidth={hot ? 2.2 : 1}
                markerEnd="url(#arrow)"
              />
            );
          })}
        </svg>
        {cols.map((c, ci) => (
          <div key={c.type} className="absolute top-0 text-xs font-semibold uppercase tracking-wide text-mute" style={{ left: ci * (W + GX), width: W }}>
            {TYPE_META[c.type].plural} <span className="font-normal">({c.docs.length})</span>
          </div>
        ))}
        {docs.map((d) => {
          const p = pos.get(d.id)!;
          return (
            <div key={d.id} className="absolute" style={{ left: p.x, top: p.y, width: W, height: H }}>
              <DocCard doc={d} selected={d.id === selectedId} onClick={() => onSelect(d.id)} />
              {unresolved.has(d.id) && (
                <span className="absolute -right-2 -top-2 rounded-full bg-red-500 p-1 text-white" title="Has a reference that resolves to nothing">
                  <AlertTriangle size={12} />
                </span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
