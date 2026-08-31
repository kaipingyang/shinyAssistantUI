// Optional Claude addin integration. Generic assistant widgets never create this
// bridge and therefore register no copilot-specific handlers or inputs.
declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export type CopilotServiceStatus =
  | "disabled"
  | "checking"
  | "starting"
  | "ready"
  | "failed";

export type CopilotServiceState = {
  status: CopilotServiceStatus;
  autoStart: boolean;
  message?: string;
};

export type CopilotServiceAddonConfig = {
  version: 1;
  state: CopilotServiceState;
};

export const isCopilotServiceStatus = (
  value: unknown,
): value is CopilotServiceStatus =>
  value === "disabled" || value === "checking" || value === "starting" ||
  value === "ready" || value === "failed";

export function parseCopilotServiceAddon(
  config: Record<string, unknown> | undefined,
): CopilotServiceAddonConfig | undefined {
  const addons = config?.addons;
  if (!addons || typeof addons !== "object") return undefined;
  const candidate = (addons as Record<string, unknown>).copilotService;
  if (!candidate || typeof candidate !== "object") return undefined;
  const raw = candidate as { version?: unknown; state?: unknown };
  if (raw.version !== 1 || !raw.state || typeof raw.state !== "object") return undefined;
  const state = raw.state as Partial<CopilotServiceState>;
  if (!isCopilotServiceStatus(state.status) || typeof state.autoStart !== "boolean") {
    return undefined;
  }
  return {
    version: 1,
    state: {
      status: state.status,
      autoStart: state.autoStart,
      ...(typeof state.message === "string" ? { message: state.message } : {}),
    },
  };
}

export type CopilotServiceBridge = {
  onStatus: (handler: (state: CopilotServiceState) => void) => void;
  sendReady: () => void;
  setAutoStart: (value: boolean) => void;
  retry: () => void;
};

export function createCopilotServiceBridge(inputId: string): CopilotServiceBridge {
  let statusHandler: ((state: CopilotServiceState) => void) | null = null;
  let bufferedStatus: CopilotServiceState | null = null;

  Shiny.addCustomMessageHandler(`${inputId}:copilot-service-status`, (data) => {
    const value = data as Partial<CopilotServiceState>;
    if (!isCopilotServiceStatus(value?.status) || typeof value.autoStart !== "boolean") return;
    const state: CopilotServiceState = {
      status: value.status,
      autoStart: value.autoStart,
      ...(typeof value.message === "string" ? { message: value.message } : {}),
    };
    if (statusHandler) statusHandler(state);
    else bufferedStatus = state;
  });

  const send = (suffix: string, value: Record<string, unknown> = {}) => {
    Shiny.setInputValue(
      `${inputId}_${suffix}`,
      { ...value, ts: Date.now() },
      { priority: "event" },
    );
  };

  return {
    onStatus(handler) {
      statusHandler = handler;
      if (bufferedStatus) {
        handler(bufferedStatus);
        bufferedStatus = null;
      }
    },
    sendReady() {
      send("copilot_service_ready");
    },
    setAutoStart(value) {
      send("copilot_auto_start", { value });
    },
    retry() {
      send("copilot_retry");
    },
  };
}
