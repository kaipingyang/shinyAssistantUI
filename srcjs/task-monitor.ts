export type TaskMonitorEvent = {
  threadId: string;
  taskId: string;
  kind: string;
  description?: string;
  status?: string;
  toolName?: string;
  summary?: string;
};

export type MonitoredTask = TaskMonitorEvent & {
  startedAt: number;
  updatedAt: number;
  stopping: boolean;
};

export type TaskMonitorState = {
  byThread: Record<string, Record<string, MonitoredTask>>;
  maxRecentTerminal: number;
};

export type ThreadTaskMonitor = {
  active: MonitoredTask[];
  recentTerminal: MonitoredTask[];
};

const TERMINAL = /^(completed|done|stopped|failed|killed|cancelled|canceled|errored)$/i;
export const isTaskTerminalStatus = (status?: string) => TERMINAL.test(status ?? "");
const isTerminal = isTaskTerminalStatus;

export function createTaskMonitorState(maxRecentTerminal = 20): TaskMonitorState {
  return { byThread: {}, maxRecentTerminal: Math.max(1, Math.floor(maxRecentTerminal)) };
}

function boundedThread(
  tasks: Record<string, MonitoredTask>,
  maxRecentTerminal: number,
): Record<string, MonitoredTask> {
  const terminal = Object.values(tasks)
    .filter((task) => isTerminal(task.status))
    .sort((a, b) => b.updatedAt - a.updatedAt);
  if (terminal.length <= maxRecentTerminal) return tasks;
  const keep = new Set(terminal.slice(0, maxRecentTerminal).map((task) => task.taskId));
  return Object.fromEntries(Object.entries(tasks).filter(([, task]) =>
    !isTerminal(task.status) || keep.has(task.taskId),
  ));
}

export function reduceTaskMonitorEvent(
  state: TaskMonitorState,
  event: TaskMonitorEvent,
  now = Date.now(),
): TaskMonitorState {
  if (!event.threadId || !event.taskId) return state;
  const previousThread = state.byThread[event.threadId] ?? {};
  const previous = previousThread[event.taskId];
  const previousTerminal = isTerminal(previous?.status);
  const incomingTerminal = isTerminal(event.status);
  const status = previousTerminal && !incomingTerminal
    ? previous.status
    : event.status ?? previous?.status ?? "running";
  const task: MonitoredTask = {
    ...(previous ?? event),
    ...event,
    status,
    startedAt: previous?.startedAt ?? now,
    updatedAt: now,
    stopping: incomingTerminal || isTerminal(status) ? false : previous?.stopping ?? false,
    description: event.description ?? previous?.description,
    toolName: event.toolName ?? previous?.toolName,
    summary: event.summary ?? previous?.summary,
  };
  const nextThread = boundedThread(
    { ...previousThread, [event.taskId]: task },
    state.maxRecentTerminal,
  );
  return { ...state, byThread: { ...state.byThread, [event.threadId]: nextThread } };
}

export function requestTaskStop(
  state: TaskMonitorState,
  threadId: string,
  taskId: string,
  now = Date.now(),
): { state: TaskMonitorState; shouldDispatch: boolean } {
  const task = state.byThread[threadId]?.[taskId];
  if (!task || task.stopping || isTerminal(task.status)) {
    return { state, shouldDispatch: false };
  }
  const next = { ...task, stopping: true, updatedAt: now };
  return {
    state: {
      ...state,
      byThread: {
        ...state.byThread,
        [threadId]: { ...state.byThread[threadId], [taskId]: next },
      },
    },
    shouldDispatch: true,
  };
}

export function selectThreadTaskMonitor(
  state: TaskMonitorState,
  threadId: string,
): ThreadTaskMonitor {
  const tasks = Object.values(state.byThread[threadId] ?? {});
  return {
    active: tasks.filter((task) => !isTerminal(task.status)).sort((a, b) => a.startedAt - b.startedAt),
    recentTerminal: tasks.filter((task) => isTerminal(task.status)).sort((a, b) => b.updatedAt - a.updatedAt),
  };
}
