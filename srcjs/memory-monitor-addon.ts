declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export type MemoryGuardState = "normal" | "soft" | "hard" | "recovering" | "disabled" | "unknown";
export type MemoryMonitorSample = {
  state: MemoryGuardState;
  pssBytes: number;
  rssBytes: number;
  cgroupCurrentBytes: number;
  cgroupMaxBytes: number;
  cgroupLimited: boolean;
  softPssBytes: number;
  hardPssBytes: number;
  softRssBytes: number;
  hardRssBytes: number;
};
export type MemoryMonitorAddonConfig = { version: 2; ownerSeed: number; lastRevision: number };
export type MemoryMonitorFrame = {
  version: 2;
  ownerId: number;
  openId: number;
  revision: number;
  sample: MemoryMonitorSample;
};

const MAX_SAFE = Number.MAX_SAFE_INTEGER;
const CONFIG_KEYS = ["version", "ownerSeed", "lastRevision"];
const FRAME_KEYS = ["version", "ownerId", "openId", "revision", "sample"];
const SAMPLE_KEYS = [
  "state", "pssBytes", "rssBytes", "cgroupCurrentBytes", "cgroupMaxBytes",
  "cgroupLimited", "softPssBytes", "hardPssBytes", "softRssBytes", "hardRssBytes",
];
const STATES = new Set<MemoryGuardState>(["normal", "soft", "hard", "recovering", "disabled", "unknown"]);
const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, expected: readonly string[]) => {
  const actual = Object.keys(value).sort();
  const target = [...expected].sort();
  return actual.length === target.length && actual.every((key, index) => key === target[index]);
};
const positiveSafe = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value > 0;
const nonNegativeSafe = (value: unknown): value is number =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

export function parseMemoryMonitorAddon(config: Record<string, unknown> | undefined): MemoryMonitorAddonConfig | undefined {
  if (!isRecord(config?.addons)) return undefined;
  const value = config.addons.memoryMonitor;
  if (!isRecord(value) || !exactKeys(value, CONFIG_KEYS) || value.version !== 2 ||
      !positiveSafe(value.ownerSeed) || !nonNegativeSafe(value.lastRevision)) return undefined;
  return { version: 2, ownerSeed: value.ownerSeed, lastRevision: value.lastRevision };
}

function parseSample(value: unknown): MemoryMonitorSample | undefined {
  if (!isRecord(value) || !exactKeys(value, SAMPLE_KEYS) ||
      typeof value.state !== "string" || !STATES.has(value.state as MemoryGuardState) ||
      typeof value.cgroupLimited !== "boolean") return undefined;
  for (const key of SAMPLE_KEYS.slice(1)) {
    if (key !== "cgroupLimited" && !nonNegativeSafe(value[key])) return undefined;
  }
  return value as MemoryMonitorSample;
}

export function parseMemoryMonitorFrame(value: unknown): MemoryMonitorFrame | undefined {
  if (!isRecord(value) || !exactKeys(value, FRAME_KEYS) || value.version !== 2 ||
      !positiveSafe(value.ownerId) || !positiveSafe(value.openId) || !nonNegativeSafe(value.revision)) return undefined;
  const sample = parseSample(value.sample);
  return sample ? { version: 2, ownerId: value.ownerId, openId: value.openId, revision: value.revision, sample } : undefined;
}

type Owner = { receive(data: unknown): void };
type Dispatcher = { active: Owner | null };
const dispatchers = new Map<string, Dispatcher>();
const ownerCounters = new Map<string, number>();
function dispatcherFor(inputId: string): Dispatcher {
  const existing = dispatchers.get(inputId);
  if (existing) return existing;
  const dispatcher: Dispatcher = { active: null };
  dispatchers.set(inputId, dispatcher);
  try {
    Shiny.addCustomMessageHandler(`${inputId}:memory-monitor-sample`, (data) => dispatcher.active?.receive(data));
  } catch { /* fail open */ }
  return dispatcher;
}

export type MemoryMonitorBridge = {
  onSample(handler: (frame: MemoryMonitorFrame) => void): void;
  setVisible(visible: boolean): boolean;
  snapshot(): MemoryMonitorFrame | null;
  dispose(): void;
};

export function createMemoryMonitorBridge(inputId: string, config: MemoryMonitorAddonConfig): MemoryMonitorBridge {
  const dispatcher = dispatcherFor(inputId);
  const previousOwner = ownerCounters.get(inputId) ?? 0;
  const ownerId = previousOwner < config.ownerSeed
    ? config.ownerSeed
    : previousOwner < MAX_SAFE ? previousOwner + 1 : MAX_SAFE;
  ownerCounters.set(inputId, ownerId);
  let openId = 0;
  let revision = config.lastRevision;
  let visible = false;
  let frozen: MemoryMonitorFrame | null = null;
  let subscriber: ((frame: MemoryMonitorFrame) => void) | null = null;
  let disposed = false;
  let retryUsed = false;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  let pendingEnvelope: Record<string, unknown> | null = null;

  const send = (envelope: Record<string, unknown>, allowRetry: boolean): boolean => {
    try {
      Shiny.setInputValue(`${inputId}_memory_monitor_visible`, envelope, { priority: "event" });
      pendingEnvelope = null;
      return true;
    } catch {
      if (allowRetry && !retryUsed && retryTimer === undefined) {
        retryUsed = true;
        pendingEnvelope = envelope;
        retryTimer = setTimeout(() => {
          retryTimer = undefined;
          const retry = pendingEnvelope;
          if (!retry || disposed || dispatcher.active !== owner) return;
          send(retry, false);
        }, 0);
      }
      return false;
    }
  };
  const envelope = (nextVisible: boolean) => ({
    version: 2, ownerId, openId, visible: nextVisible, revision, sample: null,
  });
  const owner: Owner = {
    receive(data) {
      if (disposed || dispatcher.active !== owner || !visible || frozen) return;
      const frame = parseMemoryMonitorFrame(data);
      if (!frame || frame.ownerId !== ownerId || frame.openId !== openId || frame.revision < revision) return;
      frozen = frame;
      revision = frame.revision;
      subscriber?.(frame);
    },
  };
  dispatcher.active = owner;

  return {
    onSample(handler) {
      if (disposed || dispatcher.active !== owner) return;
      subscriber = handler;
      if (frozen) handler(frozen);
    },
    setVisible(nextVisible) {
      if (disposed || dispatcher.active !== owner || ownerId >= MAX_SAFE && previousOwner >= MAX_SAFE) return false;
      if (nextVisible) {
        if (visible) return true;
        if (openId >= MAX_SAFE) return false;
        openId += 1;
        visible = true;
        frozen = null;
        retryUsed = false;
        return send(envelope(true), true);
      }
      if (!visible) return true;
      visible = false;
      pendingEnvelope = null;
      if (retryTimer !== undefined) { clearTimeout(retryTimer); retryTimer = undefined; }
      return send(envelope(false), false);
    },
    snapshot: () => frozen,
    dispose() {
      if (disposed) return;
      if (visible) {
        visible = false;
        send(envelope(false), false);
      }
      disposed = true;
      subscriber = null;
      frozen = null;
      pendingEnvelope = null;
      if (retryTimer !== undefined) clearTimeout(retryTimer);
      retryTimer = undefined;
      if (dispatcher.active === owner) dispatcher.active = null;
    },
  };
}
