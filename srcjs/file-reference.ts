import { useCallback, useSyncExternalStore } from "react";

export type FileReferenceScope = { threadId: string; project?: string };
export type FileReferenceRequest = FileReferenceScope & {
  version: 1;
  requestId: string;
  paths: string[];
};
type FileReferenceResult = { path: string; resolvedPath: string | null };
type Entry = {
  scope: FileReferenceScope;
  path: string;
  resolved: string | null | undefined;
  checked: boolean;
  listeners: Set<() => void>;
};
export type FileReferenceClient = ReturnType<typeof createFileReferenceClient>;
export type FileReferenceView = FileReferenceScope & {
  client: FileReferenceClient;
  candidate(path: string): string;
};

let clientSequence = 0;
const keyFor = (scope: FileReferenceScope, path: string) =>
  JSON.stringify([scope.threadId, scope.project ?? "", path]);
const validPath = (value: unknown): value is string =>
  typeof value === "string" && value.length > 0 && value.length <= 4096 && !/[\0\r\n]/.test(value);
const record = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

export function createFileReferenceClient(send: (request: FileReferenceRequest) => void) {
  const clientId = ++clientSequence;
  const entries = new Map<string, Entry>();
  const queued = new Set<Entry>();
  let sequence = 0;
  let batchTimer: ReturnType<typeof setTimeout> | undefined;
  let inFlight: {
    request: FileReferenceRequest; entries: Entry[]; timeout: ReturnType<typeof setTimeout>;
  } | undefined;
  const notify = (entry: Entry) => { for (const listener of entry.listeners) listener(); };
  const trim = () => {
    for (const [key, entry] of entries) {
      if (entries.size <= 256) break;
      if (!entry.listeners.size && !queued.has(entry) && !inFlight?.entries.includes(entry)) entries.delete(key);
    }
  };
  const schedule = () => {
    if (batchTimer !== undefined || inFlight || !queued.size) return;
    batchTimer = setTimeout(flush, 25);
  };
  const finish = (results?: FileReferenceResult[]) => {
    if (!inFlight) return;
    const batch = inFlight;
    clearTimeout(batch.timeout);
    inFlight = undefined;
    const resolved = new Map(results?.map((result) => [result.path, result.resolvedPath]));
    for (const entry of batch.entries) {
      if (results) entry.resolved = resolved.get(entry.path) ?? null;
      entry.checked = true;
      notify(entry);
    }
    trim();
    schedule();
  };
  function flush() {
    batchTimer = undefined;
    if (inFlight) return;
    const first = queued.values().next().value as Entry | undefined;
    if (!first) return;
    const batch: Entry[] = [];
    for (const entry of queued) {
      if (entry.scope.threadId !== first.scope.threadId || entry.scope.project !== first.scope.project) continue;
      queued.delete(entry);
      if (entry.listeners.size) batch.push(entry);
      if (batch.length === 32) break;
    }
    if (!batch.length) { schedule(); return; }
    const request: FileReferenceRequest = {
      version: 1, requestId: `file-ref-${clientId}-${++sequence}`,
      ...first.scope, paths: batch.map((entry) => entry.path),
    };
    inFlight = {
      request, entries: batch,
      timeout: setTimeout(() => {
        console.warn("[shinyAssistantUI] File reference check timed out; keeping the previous confirmation state.");
        finish();
      }, 5000),
    };
    try { send(request); } catch (error) {
      console.warn("[shinyAssistantUI] Unable to request file reference confirmation.", error);
      finish();
    }
  }
  return {
    getSnapshot(scope: FileReferenceScope, path: string): string | null {
      return entries.get(keyFor(scope, path))?.resolved ?? null;
    },
    subscribe(scope: FileReferenceScope, path: string, listener: () => void) {
      if (!validPath(path)) return () => {};
      const key = keyFor(scope, path);
      let entry = entries.get(key);
      if (!entry) {
        entry = {
          scope: { threadId: scope.threadId, project: scope.project },
          path, resolved: undefined, checked: false, listeners: new Set(),
        };
      }
      entries.delete(key);
      entries.set(key, entry);
      entry.listeners.add(listener);
      if (!entry.checked && !inFlight?.entries.includes(entry)) queued.add(entry);
      trim();
      schedule();
      return () => {
        entry.listeners.delete(listener);
        if (!entry.listeners.size) queued.delete(entry);
        if (inFlight && inFlight.entries.every((item) => !item.listeners.size)) {
          clearTimeout(inFlight.timeout);
          inFlight = undefined;
          schedule();
        }
        if (!queued.size && batchTimer !== undefined) {
          clearTimeout(batchTimer);
          batchTimer = undefined;
        }
        trim();
      };
    },
    accept(data: unknown) {
      if (!inFlight || !record(data) || data.requestId !== inFlight.request.requestId ||
          data.threadId !== inFlight.request.threadId) return;
      const expected = new Set(inFlight.request.paths);
      const results: FileReferenceResult[] = [];
      if (data.version === 1 && Array.isArray(data.files) && data.files.length === expected.size) {
        for (const file of data.files) {
          if (!record(file) || typeof file.path !== "string" || !expected.delete(file.path) ||
              (file.resolvedPath !== null && !validPath(file.resolvedPath))) break;
          results.push({ path: file.path, resolvedPath: file.resolvedPath });
        }
      }
      if (results.length !== inFlight.request.paths.length) {
        console.warn("[shinyAssistantUI] Invalid file reference confirmation; keeping the previous confirmation state.");
        finish();
        return;
      }
      finish(results);
    },
    invalidate(threadId?: string) {
      if (inFlight && (!threadId || inFlight.request.threadId === threadId)) {
        clearTimeout(inFlight.timeout);
        inFlight = undefined;
      }
      for (const entry of entries.values()) {
        if (threadId && entry.scope.threadId !== threadId) continue;
        entry.checked = false;
        if (entry.listeners.size) queued.add(entry);
        notify(entry);
      }
      schedule();
    },
    clear() {
      if (batchTimer !== undefined) clearTimeout(batchTimer);
      if (inFlight) clearTimeout(inFlight.timeout);
      batchTimer = undefined;
      inFlight = undefined;
      queued.clear();
      entries.clear();
    },
  };
}

export function useResolvedFileReference(view: FileReferenceView | undefined, path: string | undefined) {
  const client = view?.client;
  const threadId = view?.threadId;
  const project = view?.project;
  const candidate = path && view ? view.candidate(path) : undefined;
  const subscribe = useCallback((listener: () => void) =>
    client && threadId && candidate
      ? client.subscribe({ threadId, project }, candidate, listener)
      : () => {}, [client, threadId, project, candidate]);
  const snapshot = useCallback(() =>
    client && threadId && candidate ? client.getSnapshot({ threadId, project }, candidate) : null,
  [client, threadId, project, candidate]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}
