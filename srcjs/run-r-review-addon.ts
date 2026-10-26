// Plan 163 — review R output before it is shared with Claude.
// R pushes pending run_r reviews over `${inputId}:run-r-review`; decisions and the
// toggle go back through `${inputId}_run_r_review`. "Run in Console" results are
// reviewed locally with the same panel before they are sent as a chat message.
declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export const RUN_R_REVIEW_MAX_TEXT = 200_000;

export type RunRReviewAddonConfig = { version: 1; enabled: boolean };
export type RunRReviewDecision = "approve" | "edit" | "reject";
export type RunRReview = {
  id: string;
  threadId: string;
  code: string;
  text: string;
  isError: boolean;
  /** "server" = run_r tool output awaiting Claude; "local" = Run in Console result. */
  source: "server" | "local";
  expiresAt?: number;
  /** A server decision was sent; the card stays until the backend confirms. */
  submitting?: boolean;
};
export type RunRReviewSnapshot = {
  /** Confirmed by the backend; only this value gates sharing. */
  enabled: boolean;
  /** A requested change not yet confirmed. */
  pendingEnabled?: boolean;
  reviews: readonly RunRReview[];
};
export type RunRReviewBridge = {
  subscribe(listener: () => void): () => void;
  getSnapshot(): RunRReviewSnapshot;
  decide(id: string, decision: RunRReviewDecision, text?: string): boolean;
  setEnabled(enabled: boolean): void;
  /** Queue a local review; resolves with the text to send, or null when declined. */
  reviewLocal(input: { threadId: string; code: string; text: string; isError: boolean },
    onDecision: (text: string | null) => void): void;
  dispose(): void;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, keys: readonly string[]) => {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
};
const nonEmpty = (value: unknown): value is string => typeof value === "string" && value.length > 0;

export function parseRunRReviewAddon(config: Record<string, unknown> | undefined): RunRReviewAddonConfig | undefined {
  if (!isRecord(config?.addons)) return undefined;
  const value = config.addons.runROutputReview;
  if (!isRecord(value) || !exactKeys(value, ["version", "enabled"]) || value.version !== 1 ||
      typeof value.enabled !== "boolean") return undefined;
  return { version: 1, enabled: value.enabled };
}

const REVIEW_KEYS = ["id", "threadId", "code", "text", "isError", "expiresAt"];
export function parseServerReview(value: unknown): RunRReview | undefined {
  if (!isRecord(value) || !exactKeys(value, REVIEW_KEYS) || !nonEmpty(value.id) ||
      !nonEmpty(value.threadId) || typeof value.code !== "string" ||
      typeof value.text !== "string" || typeof value.isError !== "boolean" ||
      typeof value.expiresAt !== "number" || !Number.isFinite(value.expiresAt)) return undefined;
  return {
    id: value.id, threadId: value.threadId, code: value.code, text: value.text,
    isError: value.isError, source: "server", expiresAt: value.expiresAt,
  };
}

type Owner = { receive(data: unknown): void };
const dispatchers = new Map<string, { active: Owner | null }>();
function dispatcherFor(inputId: string) {
  const existing = dispatchers.get(inputId);
  if (existing) return existing;
  const dispatcher = { active: null as Owner | null };
  dispatchers.set(inputId, dispatcher);
  try {
    Shiny.addCustomMessageHandler(`${inputId}:run-r-review`, (data) => dispatcher.active?.receive(data));
  } catch { /* Shiny unavailable: reviews never arrive, server side declines by timeout. */ }
  return dispatcher;
}

let localSerial = 0;

export function createRunRReviewBridge(inputId: string, config: RunRReviewAddonConfig): RunRReviewBridge {
  const dispatcher = dispatcherFor(inputId);
  const listeners = new Set<() => void>();
  const localCallbacks = new Map<string, (text: string | null) => void>();
  let snapshot: RunRReviewSnapshot = { enabled: config.enabled, reviews: [] };
  let disposed = false;
  const publish = (next: RunRReviewSnapshot) => {
    snapshot = next;
    for (const listener of listeners) listener();
  };
  const remove = (id: string) => {
    if (!snapshot.reviews.some((review) => review.id === id)) return false;
    publish({ ...snapshot, reviews: snapshot.reviews.filter((review) => review.id !== id) });
    return true;
  };
  const send = (payload: Record<string, unknown>): boolean => {
    try {
      Shiny.setInputValue(`${inputId}_run_r_review`, { ...payload, nonce: `${Date.now()}-${Math.random()}` },
        { priority: "event" });
      return true;
    } catch {
      return false;
    }
  };
  const setSubmitting = (id: string, submitting: boolean) => publish({
    ...snapshot,
    reviews: snapshot.reviews.map((review) => review.id === id ? { ...review, submitting } : review),
  });

  const owner: Owner = {
    receive(data) {
      if (disposed || !isRecord(data)) return;
      if (data.type === "show" && exactKeys(data, ["type", "review"])) {
        const review = parseServerReview(data.review);
        if (!review || snapshot.reviews.some((item) => item.id === review.id)) return;
        publish({ ...snapshot, reviews: [...snapshot.reviews, review] });
      } else if (data.type === "dismiss" && exactKeys(data, ["type", "id", "outcome"]) && nonEmpty(data.id)) {
        remove(data.id);
      } else if (data.type === "settings" && exactKeys(data, ["type", "enabled"]) &&
                 typeof data.enabled === "boolean") {
        publish({ enabled: data.enabled, reviews: snapshot.reviews });
      }
    },
  };
  dispatcher.active = owner;
  // Reviews pushed before this handler existed (page still loading) are lost by
  // Shiny; ask the server to resend everything still pending.
  send({ type: "sync" });

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    getSnapshot: () => snapshot,
    decide(id, decision, text) {
      if (decision !== "approve" && decision !== "edit" && decision !== "reject") return false;
      const review = snapshot.reviews.find((item) => item.id === id);
      if (!review || review.submitting) return false;
      if (decision === "edit" && (typeof text !== "string" || text.length > RUN_R_REVIEW_MAX_TEXT)) return false;
      if (review.source === "local") {
        remove(id);
        const callback = localCallbacks.get(id);
        localCallbacks.delete(id);
        callback?.(decision === "reject" ? null : decision === "edit" ? text! : review.text);
        return true;
      }
      // Keep the card until the backend's dismiss: a lost decision stays visible.
      setSubmitting(id, true);
      if (!send({ type: "decide", id, decision, ...(decision === "edit" ? { text } : {}) })) {
        setSubmitting(id, false);
        return false;
      }
      return true;
    },
    setEnabled(enabled) {
      if (!send({ type: "set_enabled", enabled })) return;
      publish({ ...snapshot, pendingEnabled: enabled });
    },
    reviewLocal(input, onDecision) {
      if (!snapshot.enabled) {
        onDecision(input.text);
        return;
      }
      localSerial += 1;
      const id = `local-${localSerial}`;
      localCallbacks.set(id, onDecision);
      publish({ ...snapshot, reviews: [...snapshot.reviews, { ...input, id, source: "local" }] });
    },
    dispose() {
      disposed = true;
      if (dispatcher.active === owner) dispatcher.active = null;
      listeners.clear();
      localCallbacks.clear();
    },
  };
}
