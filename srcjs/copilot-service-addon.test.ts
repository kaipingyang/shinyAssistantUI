import { beforeEach, describe, expect, it } from "vitest";
import {
  createCopilotServiceBridge,
  parseCopilotServiceAddon,
} from "./copilot-service-addon";

type Handler = (data: unknown) => void;
let handlers: Record<string, Handler>;
let inputs: Array<{ id: string; value: unknown }>;

beforeEach(() => {
  handlers = {};
  inputs = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (globalThis as any).Shiny = {
    addCustomMessageHandler: (type: string, handler: Handler) => { handlers[type] = handler; },
    setInputValue: (id: string, value: unknown) => inputs.push({ id, value }),
  };
});

describe("copilot service addin bridge", () => {
  it("is absent unless the opaque addon config is installed", () => {
    expect(parseCopilotServiceAddon({})).toBeUndefined();
    expect(parseCopilotServiceAddon({ addons: { other: { version: 1 } } })).toBeUndefined();
    expect(parseCopilotServiceAddon({
      addons: {
        copilotService: {
          version: 1,
          state: { status: "checking", autoStart: true },
        },
      },
    })).toEqual({
      version: 1,
      state: { status: "checking", autoStart: true },
    });
  });

  it("buffers status and uses namespaced ready, toggle, and retry channels", () => {
    const bridge = createCopilotServiceBridge("chat_input");
    handlers["chat_input:copilot-service-status"]({ status: "ready", autoStart: true });

    const received: unknown[] = [];
    bridge.onStatus((value) => received.push(value));
    expect(received).toEqual([{ status: "ready", autoStart: true }]);

    bridge.sendReady();
    bridge.setAutoStart(false);
    bridge.retry();

    expect(inputs.map((item) => item.id)).toEqual([
      "chat_input_copilot_service_ready",
      "chat_input_copilot_auto_start",
      "chat_input_copilot_retry",
    ]);
    expect(inputs[1].value).toMatchObject({ value: false });
  });
});
