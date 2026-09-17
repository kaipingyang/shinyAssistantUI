import {
  fromThreadMessageLike,
  type ExportedMessageRepository,
  type MessageStatus,
  type ThreadMessageLike,
} from "@assistant-ui/core";

export const BROWSER_MESSAGE_WINDOW = 240;
export const BROWSER_ALTERNATE_WINDOW = 24;

type OwnedMessage = ThreadMessageLike & { id: string; createdAt: Date };
type RepositoryNode = {
  message: OwnedMessage;
  parentId: string | null;
  children: string[];
  touched: number;
};

type RepositoryOptions = {
  maxVisibleMessages?: number;
  maxAlternateMessages?: number;
};

const clampLimit = (value: number | undefined, fallback: number, ceiling: number) => {
  if (!Number.isFinite(value)) return fallback;
  return Math.max(1, Math.min(ceiling, Math.floor(value!)));
};

export function boundBrowserMessages(
  messages: readonly ThreadMessageLike[],
  limit = BROWSER_MESSAGE_WINDOW,
): ThreadMessageLike[] {
  const cap = clampLimit(limit, BROWSER_MESSAGE_WINDOW, 2_000);
  if (messages.length <= cap) return [...messages];
  let start = messages.length - cap;
  // Prefer a complete ordinary turn. If the cutoff lands in assistant output,
  // advance to the next user boundary. A single enormous turn still falls back
  // to the hard message cap so the browser cannot grow without bound.
  if (messages[start]?.role !== "user") {
    const nextUser = messages.findIndex(
      (message, index) => index >= start && message.role === "user",
    );
    if (nextUser >= start) start = nextUser;
  }
  return messages.slice(start);
}

const fallbackStatus = (
  message: ThreadMessageLike,
  isLast: boolean,
  isRunning: boolean,
): MessageStatus => {
  const content = typeof message.content === "string" ? [] : message.content;
  const pending = content.some(
    (part) => part.type === "tool-call" && part.result === undefined,
  );
  const interrupted = content.some((part) =>
    part.type === "tool-call" && part.result === undefined && (
      part.interrupt != null ||
      (part.approval != null && part.approval.approved === undefined &&
        part.approval.resolution === undefined)
    ),
  );
  if (isLast && isRunning) return { type: "running" };
  if (interrupted) return { type: "requires-action", reason: "interrupt" };
  if (pending) return { type: "requires-action", reason: "tool-calls" };
  return { type: "complete", reason: "unknown" };
};

export class AppMessageRepository {
  private readonly nodes = new Map<string, RepositoryNode>();
  private roots: string[] = [];
  private headId: string | null = null;
  private sequence = 0;
  private fallbackId = 0;
  private readonly maxVisibleMessages: number;
  private readonly maxAlternateMessages: number;
  private windowRootId: string | null = null;
  private evictedBefore = false;

  constructor(options: RepositoryOptions = {}) {
    this.maxVisibleMessages = clampLimit(
      options.maxVisibleMessages,
      BROWSER_MESSAGE_WINDOW,
      2_000,
    );
    this.maxAlternateMessages = clampLimit(
      options.maxAlternateMessages,
      BROWSER_ALTERNATE_WINDOW,
      200,
    );
  }

  private normalize(message: ThreadMessageLike): OwnedMessage {
    const id = message.id ?? `repository-fallback-${++this.fallbackId}`;
    const rawCreatedAt = (message as { createdAt?: unknown }).createdAt;
    const parsed = rawCreatedAt instanceof Date
      ? rawCreatedAt
      : typeof rawCreatedAt === "string" || typeof rawCreatedAt === "number"
        ? new Date(rawCreatedAt)
        : new Date();
    const createdAt = Number.isNaN(parsed.getTime()) ? new Date() : parsed;
    return { ...message, id, createdAt };
  }

  private unlink(nodeId: string, parentId: string | null) {
    if (parentId === null) {
      this.roots = this.roots.filter((id) => id !== nodeId);
      return;
    }
    const parent = this.nodes.get(parentId);
    if (parent) parent.children = parent.children.filter((id) => id !== nodeId);
  }

  private link(nodeId: string, parentId: string | null) {
    if (parentId === null) {
      if (!this.roots.includes(nodeId)) this.roots.push(nodeId);
      return;
    }
    const parent = this.nodes.get(parentId);
    if (!parent) throw new Error(`AppMessageRepository: missing parent ${parentId}`);
    if (!parent.children.includes(nodeId)) parent.children.push(nodeId);
  }

  replaceVisiblePath(messages: readonly ThreadMessageLike[]) {
    const normalized = messages.map((message) => this.normalize(message));
    const ids = new Set<string>();
    for (const message of normalized) {
      if (ids.has(message.id)) {
        throw new Error(`AppMessageRepository: duplicate message id ${message.id}`);
      }
      ids.add(message.id);
    }

    let parentId: string | null = null;
    for (const message of normalized) {
      this.sequence += 1;
      const existing = this.nodes.get(message.id);
      if (existing) {
        if (existing.parentId !== parentId) {
          this.unlink(message.id, existing.parentId);
          existing.parentId = parentId;
          this.link(message.id, parentId);
        }
        existing.message = message;
        existing.touched = this.sequence;
      } else {
        const node: RepositoryNode = {
          message,
          parentId,
          children: [],
          touched: this.sequence,
        };
        this.nodes.set(message.id, node);
        this.link(message.id, parentId);
      }
      parentId = message.id;
    }
    this.headId = parentId;
    if (this.headId === null) {
      this.nodes.clear();
      this.roots = [];
      this.windowRootId = null;
      this.evictedBefore = false;
      return;
    }
    this.evict();
  }

  resetVisiblePath(messages: readonly ThreadMessageLike[]) {
    this.nodes.clear();
    this.roots = [];
    this.headId = null;
    this.windowRootId = null;
    this.evictedBefore = false;
    this.replaceVisiblePath(messages);
  }

  visibleMessages(): OwnedMessage[] {
    const reversed: OwnedMessage[] = [];
    const seen = new Set<string>();
    let current = this.headId;
    while (current) {
      if (seen.has(current)) throw new Error("AppMessageRepository: cycle detected");
      seen.add(current);
      const node = this.nodes.get(current);
      if (!node) throw new Error(`AppMessageRepository: missing head ancestor ${current}`);
      reversed.push(node.message);
      current = node.parentId;
    }
    return reversed.reverse();
  }

  private evict() {
    const fullPath = this.visibleMessages();
    const boundedPath = boundBrowserMessages(fullPath, this.maxVisibleMessages) as OwnedMessage[];
    const activeIds = new Set(boundedPath.map((message) => message.id));
    const evictedPrefix = new Set(
      fullPath.slice(0, fullPath.length - boundedPath.length).map((message) => message.id),
    );
    if (evictedPrefix.size > 0) this.evictedBefore = true;

    const rootId = boundedPath[0]?.id ?? null;
    this.windowRootId = rootId;
    if (rootId) {
      const root = this.nodes.get(rootId)!;
      if (root.parentId !== null) {
        this.unlink(rootId, root.parentId);
        root.parentId = null;
        this.link(rootId, null);
      }
    }

    // Keep only a small recency-ranked set of alternate nodes whose parent is
    // still retained. Evicted active ancestors are never resurrected as roots.
    const retained = new Set(activeIds);
    const candidates = [...this.nodes.entries()]
      .filter(([id]) => !activeIds.has(id) && !evictedPrefix.has(id))
      .sort((left, right) => right[1].touched - left[1].touched);
    let alternateCount = 0;
    let progressed = true;
    while (progressed && alternateCount < this.maxAlternateMessages) {
      progressed = false;
      for (const [id, node] of candidates) {
        if (retained.has(id) || alternateCount >= this.maxAlternateMessages) continue;
        if (node.parentId !== null && !retained.has(node.parentId)) continue;
        retained.add(id);
        alternateCount += 1;
        progressed = true;
      }
    }

    for (const id of [...this.nodes.keys()]) {
      if (!retained.has(id)) this.nodes.delete(id);
    }
    for (const node of this.nodes.values()) {
      node.children = node.children.filter((id) => this.nodes.has(id));
      if (node.parentId !== null && !this.nodes.has(node.parentId)) node.parentId = null;
    }
    this.roots = [...this.nodes.entries()]
      .filter(([, node]) => node.parentId === null)
      .map(([id]) => id);
  }

  export(isRunning: boolean): ExportedMessageRepository {
    const output: ExportedMessageRepository["messages"] = [];
    const visited = new Set<string>();
    const visit = (id: string) => {
      if (visited.has(id)) return;
      const node = this.nodes.get(id);
      if (!node) return;
      visited.add(id);
      output.push({
        parentId: node.parentId,
        message: fromThreadMessageLike(
          node.message,
          node.message.id,
          fallbackStatus(node.message, id === this.headId, isRunning),
        ),
      });
      for (const childId of node.children) visit(childId);
    };
    for (const rootId of this.roots) visit(rootId);
    return { headId: this.headId, messages: output };
  }

  snapshot() {
    return {
      headId: this.headId,
      windowRootId: this.windowRootId,
      evictedBefore: this.evictedBefore,
      nodeCount: this.nodes.size,
      visibleIds: this.visibleMessages().map((message) => message.id),
    };
  }
}
