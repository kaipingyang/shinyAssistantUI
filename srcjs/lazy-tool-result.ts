import { useCallback, useEffect, useSyncExternalStore } from "react";

export type LazyToolResultDescriptor = {
  kind: "lazy-tool-result";
  version: 1;
  handle: string;
  generation: number;
  threadId: string;
  toolCallId: string;
  /** Bytes available through this bounded lazy artifact. */
  originalBytes: number;
  /** Bytes in the source result before the server-side UI hard ceiling. */
  sourceBytes: number;
  truncated: boolean;
  chunkBytes: number;
  summary: string;
};

export type LazyToolResultRequest = {
  handle: string;
  generation: number;
  threadId: string;
  toolCallId: string;
  requestId: string;
  offset: number;
  maxBytes: number;
};

export type LazyToolResultChunk = LazyToolResultRequest & {
  text?: string;
  nextOffset?: number;
  done?: boolean;
  error?: string;
};

export type LazyToolResultSnapshot = {
  text: string;
  loading: boolean;
  done: boolean;
  error: string | null;
  nextOffset: number;
  retainedBytes: number;
  droppedBytes: number;
  droppedLineBreaks: number;
};

export type LazyToolResultClient = ReturnType<typeof createLazyToolResultClient>;

const EMPTY_SNAPSHOT: LazyToolResultSnapshot = Object.freeze({
  text: "", loading: false, done: false, error: null, nextOffset: 0,
  retainedBytes: 0, droppedBytes: 0, droppedLineBreaks: 0,
});

const finiteNonNegative = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value) && value >= 0;

export function isLazyToolResultDescriptor(value: unknown): value is LazyToolResultDescriptor {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Partial<LazyToolResultDescriptor>;
  return item.kind === "lazy-tool-result" && item.version === 1 &&
    typeof item.handle === "string" && item.handle.length > 0 &&
    Number.isInteger(item.generation) && finiteNonNegative(item.generation) &&
    typeof item.threadId === "string" && item.threadId.length > 0 &&
    typeof item.toolCallId === "string" && item.toolCallId.length > 0 &&
    finiteNonNegative(item.originalBytes) && Number.isInteger(item.originalBytes) &&
    finiteNonNegative(item.sourceBytes) && Number.isInteger(item.sourceBytes) &&
    item.sourceBytes >= item.originalBytes &&
    typeof item.truncated === "boolean" &&
    item.truncated === (item.sourceBytes > item.originalBytes) &&
    typeof item.chunkBytes === "number" && Number.isInteger(item.chunkBytes) && item.chunkBytes >= 4 &&
    typeof item.summary === "string";
}

type Chunk = { text: string; bytes: number; lineBreaks: number };
type Entry = {
  descriptor: LazyToolResultDescriptor;
  active: boolean;
  chunks: Chunk[];
  retainedBytes: number;
  droppedBytes: number;
  droppedLineBreaks: number;
  nextOffset: number;
  done: boolean;
  loading: boolean;
  error: string | null;
  pending: LazyToolResultRequest | null;
  listeners: Set<() => void>;
  snapshot: LazyToolResultSnapshot;
};

const descriptorKey = (descriptor: LazyToolResultDescriptor) =>
  `${descriptor.handle}::${descriptor.generation}`;
const lineBreakCount = (text: string) => (text.match(/\n/g) ?? []).length;

export function createLazyToolResultClient(
  send: (request: LazyToolResultRequest) => void,
  options: { retainedBytes?: number } = {},
) {
  const retainedBudget = Math.max(4, Math.floor(options.retainedBytes ?? 512 * 1024));
  const entries = new Map<string, Entry>();
  let requestSequence = 0;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", { fatal: false });

  const buildSnapshot = (entry: Entry): LazyToolResultSnapshot => ({
    text: entry.chunks.map((chunk) => chunk.text).join(""),
    loading: entry.loading,
    done: entry.done,
    error: entry.error,
    nextOffset: entry.nextOffset,
    retainedBytes: entry.retainedBytes,
    droppedBytes: entry.droppedBytes,
    droppedLineBreaks: entry.droppedLineBreaks,
  });

  const notify = (entry: Entry) => {
    entry.snapshot = buildSnapshot(entry);
    for (const listener of entry.listeners) listener();
  };

  const ensure = (descriptor: LazyToolResultDescriptor): Entry => {
    const key = descriptorKey(descriptor);
    const existing = entries.get(key);
    if (existing) {
      existing.descriptor = descriptor;
      return existing;
    }
    const entry: Entry = {
      descriptor, active: false, chunks: [], retainedBytes: 0, droppedBytes: 0,
      droppedLineBreaks: 0, nextOffset: 0, done: false, loading: false,
      error: null, pending: null, listeners: new Set(), snapshot: EMPTY_SNAPSHOT,
    };
    entries.set(key, entry);
    return entry;
  };

  const issue = (
    entry: Entry,
    descriptor: LazyToolResultDescriptor,
    threadId: string,
    toolCallId: string,
  ) => {
    if (!entry.active || entry.loading || entry.done) return;
    const request: LazyToolResultRequest = {
      handle: descriptor.handle,
      generation: descriptor.generation,
      threadId,
      toolCallId,
      requestId: `lazy-result-${Date.now()}-${++requestSequence}`,
      offset: entry.nextOffset,
      maxBytes: descriptor.chunkBytes,
    };
    entry.loading = true;
    entry.error = null;
    entry.pending = request;
    notify(entry);
    send(request);
  };

  return {
    getSnapshot(descriptor: LazyToolResultDescriptor): LazyToolResultSnapshot {
      return entries.get(descriptorKey(descriptor))?.snapshot ?? EMPTY_SNAPSHOT;
    },

    subscribe(descriptor: LazyToolResultDescriptor, listener: () => void) {
      const key = descriptorKey(descriptor);
      const entry = ensure(descriptor);
      entry.listeners.add(listener);
      return () => {
        entry.listeners.delete(listener);
        if (!entry.active && entry.listeners.size === 0) entries.delete(key);
      };
    },

    open(descriptor: LazyToolResultDescriptor, threadId: string, toolCallId: string) {
      const entry = ensure(descriptor);
      entry.active = true;
      issue(entry, descriptor, threadId, toolCallId);
    },

    requestNext(descriptor: LazyToolResultDescriptor, threadId: string, toolCallId: string) {
      const entry = entries.get(descriptorKey(descriptor));
      if (!entry) return;
      issue(entry, descriptor, threadId, toolCallId);
    },

    close(descriptor: LazyToolResultDescriptor) {
      const key = descriptorKey(descriptor);
      const entry = entries.get(key);
      if (!entry) return;
      entry.active = false;
      entry.chunks = [];
      entry.retainedBytes = 0;
      entry.droppedBytes = 0;
      entry.droppedLineBreaks = 0;
      entry.nextOffset = 0;
      entry.done = false;
      entry.loading = false;
      entry.error = null;
      entry.pending = null;
      notify(entry);
      if (entry.listeners.size === 0) entries.delete(key);
    },

    accept(chunk: LazyToolResultChunk) {
      const key = `${chunk.handle}::${chunk.generation}`;
      const entry = entries.get(key);
      const pending = entry?.pending;
      if (!entry || !entry.active || !pending ||
          chunk.requestId !== pending.requestId || chunk.offset !== pending.offset ||
          chunk.threadId !== pending.threadId || chunk.toolCallId !== pending.toolCallId) return;

      entry.pending = null;
      entry.loading = false;
      if (typeof chunk.error === "string" && chunk.error) {
        entry.error = chunk.error;
        notify(entry);
        return;
      }
      if (typeof chunk.text !== "string" || !finiteNonNegative(chunk.nextOffset) ||
          !Number.isInteger(chunk.nextOffset) || chunk.nextOffset < chunk.offset ||
          chunk.nextOffset > entry.descriptor.originalBytes) return;

      const bytes = encoder.encode(chunk.text).byteLength;
      if (bytes > 0) {
        entry.chunks.push({ text: chunk.text, bytes, lineBreaks: lineBreakCount(chunk.text) });
        entry.retainedBytes += bytes;
      }
      entry.nextOffset = chunk.nextOffset;
      entry.done = chunk.done === true || entry.nextOffset >= entry.descriptor.originalBytes;
      while (entry.retainedBytes > retainedBudget && entry.chunks.length > 1) {
        const removed = entry.chunks.shift()!;
        entry.retainedBytes -= removed.bytes;
        entry.droppedBytes += removed.bytes;
        entry.droppedLineBreaks += removed.lineBreaks;
      }
      if (entry.retainedBytes > retainedBudget && entry.chunks.length === 1) {
        const only = entry.chunks[0];
        const raw = encoder.encode(only.text);
        let start = Math.max(0, raw.byteLength - retainedBudget);
        while (start < raw.byteLength && (raw[start] & 0xc0) === 0x80) start += 1;
        const removedText = decoder.decode(raw.slice(0, start));
        const keptText = decoder.decode(raw.slice(start));
        const kept = raw.slice(start);
        entry.chunks[0] = {
          text: keptText, bytes: kept.byteLength, lineBreaks: lineBreakCount(keptText),
        };
        entry.retainedBytes = kept.byteLength;
        entry.droppedBytes += start;
        entry.droppedLineBreaks += lineBreakCount(removedText);
      }
      notify(entry);
    },
  };
}

export function useLazyToolResult(
  client: LazyToolResultClient | undefined,
  descriptor: LazyToolResultDescriptor | undefined,
  open: boolean,
  threadId: string,
  toolCallId: string,
) {
  const subscribe = useCallback((listener: () => void) => {
    if (!client || !descriptor || !open) return () => {};
    return client.subscribe(descriptor, listener);
  }, [client, descriptor, open]);
  const getSnapshot = useCallback(
    () => client && descriptor && open ? client.getSnapshot(descriptor) : EMPTY_SNAPSHOT,
    [client, descriptor, open],
  );
  const snapshot = useSyncExternalStore(subscribe, getSnapshot, getSnapshot);

  useEffect(() => {
    if (!client || !descriptor) return;
    if (open) client.open(descriptor, threadId, toolCallId);
    else client.close(descriptor);
    return () => client.close(descriptor);
  }, [client, descriptor, open, threadId, toolCallId]);

  const requestNext = useCallback(() => {
    if (client && descriptor && open) {
      client.requestNext(descriptor, threadId, toolCallId);
    }
  }, [client, descriptor, open, threadId, toolCallId]);

  return { snapshot, requestNext };
}
