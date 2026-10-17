export type Doc = {
  id: string;
  type: string;
  title: string;
  status: string;
  priority: string;
  date: string;
  tags: string[];
  refines: string[];
  affects: string[];
  summary: string;
  body: string;
  path: string;
  isNew?: boolean;
};

export type Filters = {
  types: string[];
  statuses: string[];
  priority: string;
  tag: string;
  text: string;
  widen: number;
};

export type AgentStatus =
  | "working"
  | "waiting-input"
  | "waiting-approval"
  | "idle"
  | "finished"
  | "failed"
  | "unknown";

export type Session = {
  id: string;
  task: string;
  repository: string;
  status: AgentStatus;
  since: string;
};

export type AdapterMode = "full" | "list-only" | "none";
