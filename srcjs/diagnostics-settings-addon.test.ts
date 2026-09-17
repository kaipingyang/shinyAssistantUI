import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  createDiagnosticsSettingsBridge,
  parseDiagnosticsSettingsAddon,
  parseDiagnosticsLaunchConfig,
  parseDiagnosticsSettingsCanonical,
  parseDiagnosticsSettingsResult,
  type DiagnosticsSettingsBind,
} from "./diagnostics-settings-addon";

type Handler = (data: unknown) => void;
let handlers: Record<string, Handler>;
let inputs: Array<{ id: string; value: unknown; opts?: unknown }>;
let serial = 0;

const fields: DiagnosticsSettingsBind["fields"] = {
  autoStartCopilotApi: { value: true, revision: 0 },
  defaultPermissionMode: { value: "default", revision: 0 },
  modeVisibility: { value: { showBypass: true, showYolo: true }, revision: 0 },
  composerDensity: { value: "comfortable", revision: 0 },
  assistantTextSize: { value: "medium", revision: 0 },
  runREnabled: { value: true, revision: 0 },
  showClaudeEditsInRStudio: { value: true, revision: 0 },
  diagnosticsEnabled: { value: true, revision: 0 },
  showPerformanceOrb: { value: true, revision: 0 },
};
const bind = (ownerId = 41): DiagnosticsSettingsBind => ({
  version: 2,
  kind: "settings_bind",
  ownerSeed: ownerId,
  ownerId,
  fields,
});

beforeEach(() => {
  handlers = {};
  inputs = [];
  serial += 1;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (globalThis as any).Shiny = {
    addCustomMessageHandler: (type: string, handler: Handler) => { handlers[type] = handler; },
    setInputValue: (id: string, value: unknown, opts?: unknown) => inputs.push({ id, value, opts }),
  };
});

describe("diagnostics settings exact v2 bridge", () => {
  it("accepts only a complete exact bind with R-issued matching owner", () => {
    expect(parseDiagnosticsSettingsAddon({ addons: { diagnosticsSettings: bind() } })).toEqual(bind());
    expect(parseDiagnosticsSettingsAddon({ addons: { diagnosticsSettings: { ...bind(), ownerId: 42 } } })).toBeUndefined();
    expect(parseDiagnosticsSettingsAddon({ addons: { diagnosticsSettings: { ...bind(), path: "/private" } } })).toBeUndefined();
    const missing = { ...fields } as Partial<typeof fields>;
    delete missing.showPerformanceOrb;
    expect(parseDiagnosticsSettingsAddon({ addons: { diagnosticsSettings: { ...bind(), fields: missing } } })).toBeUndefined();
    expect(parseDiagnosticsSettingsAddon({ addons: { diagnosticsSettings: {
      ...bind(), fields: { ...fields, diagnosticsEnabled: { value: "true", revision: 0 } },
    } } })).toBeUndefined();
  });


  it("parses restart-bound launch truth separately from the exact settings bind", () => {
    const launch = {
      version: 2, launchEnabled: true, environmentOverride: "on",
      launchKind: "job", writerStartup: "failed",
    } as const;
    expect(parseDiagnosticsLaunchConfig({ addons: { diagnosticsLaunch: launch } })).toEqual(launch);
    expect(parseDiagnosticsLaunchConfig({ addons: { diagnosticsLaunch: { ...launch, path: "/secret" } } })).toBeUndefined();
    expect(parseDiagnosticsLaunchConfig({ addons: { diagnosticsLaunch: { ...launch, launchEnabled: 1 } } })).toBeUndefined();
  });
  it("strictly enforces result boolean/category iff and canonical envelopes", () => {
    const ok = {
      version: 2, kind: "settings_result", field: "diagnosticsEnabled", ownerId: 41,
      requestId: 1, revision: 1, ok: true, category: "ok", value: false,
    } as const;
    expect(parseDiagnosticsSettingsResult(ok)).toEqual(ok);
    expect(parseDiagnosticsSettingsResult({ ...ok, ok: false })).toBeUndefined();
    expect(parseDiagnosticsSettingsResult({ ...ok, category: "busy" })).toBeUndefined();
    expect(parseDiagnosticsSettingsResult({ ...ok, ok: 1 })).toBeUndefined();
    expect(parseDiagnosticsSettingsResult({ ...ok, error: "SECRET" })).toBeUndefined();

    const canonical = {
      version: 2, kind: "settings_canonical", field: "showPerformanceOrb",
      revision: 3, value: false,
    } as const;
    expect(parseDiagnosticsSettingsCanonical(canonical)).toEqual(canonical);
    expect(parseDiagnosticsSettingsCanonical({ ...canonical, ownerId: 41 })).toBeUndefined();
  });

  it("sends owner-ready and exact field CAS request, then accepts matching ack", () => {
    const inputId = `settings-v2-${serial}`;
    const bridge = createDiagnosticsSettingsBridge(inputId, bind());
    expect(inputs[0]).toEqual({
      id: `${inputId}_diagnostics_settings_ready`,
      value: { version: 2, kind: "settings_ready", ownerId: 41 },
      opts: { priority: "event" },
    });
    expect(bridge.snapshot().fields.showPerformanceOrb.value).toBe(true);

    const pending = bridge.request("showPerformanceOrb", false);
    expect(pending).toEqual({ ownerId: 41, requestId: 1 });
    expect(inputs[1]).toEqual({
      id: `${inputId}_diagnostics_setting`,
      value: {
        version: 2, kind: "settings_request", field: "showPerformanceOrb",
        ownerId: 41, requestId: 1, expectedRevision: 0, value: false,
      },
      opts: { priority: "event" },
    });
    expect(bridge.snapshot().fields.showPerformanceOrb.pending).toBe(true);

    handlers[`${inputId}:diagnostics-settings-canonical`]({
      version: 2, kind: "settings_canonical", field: "showPerformanceOrb",
      revision: 1, value: false,
    });
    handlers[`${inputId}:diagnostics-settings-result`]({
      version: 2, kind: "settings_result", field: "showPerformanceOrb", ownerId: 41,
      requestId: 1, revision: 1, ok: true, category: "ok", value: false,
    });
    expect(bridge.snapshot().fields.showPerformanceOrb).toMatchObject({
      value: false, revision: 1, pending: false, category: "ok",
    });
    bridge.dispose();
  });

  it("keeps two bindings independent and drops stale owner/frame conflicts", () => {
    const firstId = `settings-a-${serial}`;
    const secondId = `settings-b-${serial}`;
    const first = createDiagnosticsSettingsBridge(firstId, bind(10));
    const second = createDiagnosticsSettingsBridge(secondId, bind(20));
    first.request("diagnosticsEnabled", false);
    second.request("showPerformanceOrb", false);
    expect(inputs.filter((entry) => entry.id.endsWith("_diagnostics_setting"))).toHaveLength(2);

    handlers[`${firstId}:diagnostics-settings-result`]({
      version: 2, kind: "settings_result", field: "diagnosticsEnabled", ownerId: 9,
      requestId: 1, revision: 1, ok: true, category: "ok", value: false,
    });
    expect(first.snapshot().fields.diagnosticsEnabled.pending).toBe(true);

    handlers[`${firstId}:diagnostics-settings-canonical`]({
      version: 2, kind: "settings_canonical", field: "diagnosticsEnabled", revision: 2, value: false,
    });
    handlers[`${firstId}:diagnostics-settings-canonical`]({
      version: 2, kind: "settings_canonical", field: "diagnosticsEnabled", revision: 1, value: true,
    });
    handlers[`${firstId}:diagnostics-settings-canonical`]({
      version: 2, kind: "settings_canonical", field: "diagnosticsEnabled", revision: 2, value: true,
    });
    expect(first.snapshot().fields.diagnosticsEnabled.value).toBe(false);
    expect(second.snapshot().fields.diagnosticsEnabled.value).toBe(true);
    first.dispose();
    second.dispose();
  });

  it("accepts an exact higher R-issued rebind and restarts owner-local requests", () => {
    const inputId = `settings-remount-${serial}`;
    const bridge = createDiagnosticsSettingsBridge(inputId, bind(41));
    expect(bridge.request("showPerformanceOrb", false)).toEqual({ ownerId: 41, requestId: 1 });
    expect(bridge.snapshot().fields.showPerformanceOrb.pending).toBe(true);

    const rebound = bind(42);
    handlers[`${inputId}:diagnostics-settings-bind`](rebound);
    expect(inputs.at(-1)).toEqual({
      id: `${inputId}_diagnostics_settings_ready`,
      value: { version: 2, kind: "settings_ready", ownerId: 42 },
      opts: { priority: "event" },
    });
    expect(bridge.snapshot().ownerId).toBe(42);
    expect(bridge.snapshot().fields.showPerformanceOrb.pending).toBe(false);
    expect(bridge.request("showPerformanceOrb", false)).toEqual({ ownerId: 42, requestId: 1 });

    handlers[`${inputId}:diagnostics-settings-result`]({
      version: 2, kind: "settings_result", field: "showPerformanceOrb", ownerId: 41,
      requestId: 1, revision: 1, ok: true, category: "ok", value: false,
    });
    expect(bridge.snapshot().fields.showPerformanceOrb.pending).toBe(true);
    handlers[`${inputId}:diagnostics-settings-bind`](bind(41));
    expect(bridge.snapshot().ownerId).toBe(42);
    bridge.dispose();
  });

  it("disables exhausted request ids and fails open on transport errors", () => {
    const inputId = `settings-max-${serial}`;
    const bridge = createDiagnosticsSettingsBridge(inputId, bind(7), Number.MAX_SAFE_INTEGER);
    expect(bridge.request("diagnosticsEnabled", false)).toBeNull();
    expect(bridge.snapshot().disabled).toBe(true);
    bridge.dispose();

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    (globalThis as any).Shiny.setInputValue = vi.fn(() => { throw new Error("unavailable"); });
    const failed = createDiagnosticsSettingsBridge(`${inputId}-throw`, bind(8));
    expect(failed.request("diagnosticsEnabled", false)).toBeNull();
    expect(failed.snapshot().fields.diagnosticsEnabled.pending).toBe(false);
    failed.dispose();
  });
});
