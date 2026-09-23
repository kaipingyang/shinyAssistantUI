import type { FileReferenceScope } from "./file-reference";

export type FileOpenRequest = FileReferenceScope & {
  version: 1;
  requestId: string;
  path: string;
  line?: number;
};
type Pending = {
  key: string;
  request: FileOpenRequest;
  promise: Promise<boolean>;
  resolve(ok: boolean): void;
  timeout: ReturnType<typeof setTimeout>;
};
let ownerSequence = 0;

export function createFileOpenClient(send: (request: FileOpenRequest) => void) {
  const owner = ++ownerSequence;
  const pending = new Map<string, Pending>();
  const byKey = new Map<string, Pending>();
  let sequence = 0;
  const finish = (entry: Pending, ok: boolean) => {
    clearTimeout(entry.timeout);
    pending.delete(entry.request.requestId);
    byKey.delete(entry.key);
    entry.resolve(ok);
  };
  return {
    open(path: string, line: number | undefined, scope: FileReferenceScope): Promise<boolean> {
      const key = JSON.stringify([scope.threadId, scope.project, path, line]);
      const existing = byKey.get(key);
      if (existing) return existing.promise;
      const request: FileOpenRequest = {
        version: 1, requestId: `file-open-${owner}-${++sequence}`,
        threadId: scope.threadId, project: scope.project, path, line,
      };
      let resolve!: (ok: boolean) => void;
      const promise = new Promise<boolean>((settle) => { resolve = settle; });
      const entry: Pending = {
        key, request, promise, resolve,
        timeout: setTimeout(() => {
          console.warn("[shinyAssistantUI] File opening was not acknowledged; retry explicitly.");
          finish(entry, false);
        }, 10000),
      };
      pending.set(request.requestId, entry);
      byKey.set(key, entry);
      try { send(request); } catch (error) {
        console.warn("[shinyAssistantUI] Unable to request file opening.", error);
        finish(entry, false);
      }
      return promise;
    },
    accept(data: unknown) {
      if (!data || typeof data !== "object" || !("requestId" in data) ||
          typeof data.requestId !== "string") return;
      const entry = pending.get(data.requestId);
      if (!entry || !("threadId" in data) || data.threadId !== entry.request.threadId) return;
      if (!("version" in data) || data.version !== 1 || !("ok" in data) || typeof data.ok !== "boolean") {
        console.warn("[shinyAssistantUI] Invalid file opening acknowledgement.");
        finish(entry, false);
        return;
      }
      finish(entry, data.ok);
    },
    clear() {
      for (const entry of pending.values()) finish(entry, false);
    },
  };
}
