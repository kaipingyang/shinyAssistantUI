import { describe, expect, it, vi } from "vitest";
// @ts-expect-error -- Vite's ?raw loader supplies this test-only source string.
import protocolSource from "./protocol.ts?raw";

const upstreamSpies = vi.hoisted(() => ({
  reducer: vi.fn(),
  converter: vi.fn(),
  snapshot: vi.fn(),
}));

vi.mock("@assistant-ui/react-generative-ui/a2ui", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@assistant-ui/react-generative-ui/a2ui")>();
  upstreamSpies.reducer.mockImplementation(actual.applyA2uiOperations);
  upstreamSpies.converter.mockImplementation(actual.convertSurfaceToUISpec);
  upstreamSpies.snapshot.mockImplementation(actual.surfaceToOperations);
  return {
    ...actual,
    applyA2uiOperations: upstreamSpies.reducer,
    convertSurfaceToUISpec: upstreamSpies.converter,
    surfaceToOperations: upstreamSpies.snapshot,
  };
});

import {
  A2UI_LIMITS,
  A2uiProtocolController,
  applyMessagePatch,
  classifyCanonicalPart,
  commitPreparedTransaction,
  createControllerState,
  filterA2uiSpec,
  getCanonicalA2uiMarker,
  makeA2uiValidationFeedback,
  normalizeCanonicalA2uiPart,
  prepareEnvelopeTransaction,
  toPresentA2uiPart,
  sha256Utf8,
  stableJsonSha256,
  validateA2uiEnvelope,
  type A2uiEnvelope,
  type CanonicalA2uiPart,
  type ProtocolDependencies,
} from "./protocol";
import {
  applyA2uiOperations,
  convertSurfaceToUISpec,
  surfaceToOperations,
} from "@assistant-ui/react-generative-ui/a2ui";

const CATALOG = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json";
const CATALOG_091 = "https://a2ui.org/specification/v0_9_1/catalogs/basic/catalog.json";

const create = (surfaceId = "surface-1") => ({
  version: "v0.9" as const,
  createSurface: { surfaceId },
});
const root = (surfaceId = "surface-1", text = "hello") => ({
  version: "v0.9" as const,
  updateComponents: {
    surfaceId,
    components: [{ id: "root", component: "Text", text }],
  },
});
const data = (sequence: number, surfaceId = "surface-1") => ({
  version: "v0.9" as const,
  updateDataModel: { surfaceId, path: "/", contents: { sequence } },
});
const remove = (surfaceId = "surface-1") => ({
  version: "v0.9" as const,
  deleteSurface: { surfaceId },
});

function envelope(
  sequence: number,
  operations: unknown[] = sequence === 1 ? [create(), root()] : [data(sequence)],
  overrides: Partial<A2uiEnvelope> = {},
): A2uiEnvelope {
  return {
    transportVersion: 1,
    threadId: "thread-1",
    runId: "run-1",
    eventId: `event-${sequence}`,
    sequence,
    operations,
    ...overrides,
  } as A2uiEnvelope;
}

function liveController(threadId = "thread-1", runId = "run-1", messageId = "message-1") {
  const controller = new A2uiProtocolController();
  controller.activateRun(threadId, runId, messageId);
  return controller;
}

function acceptedSurface(controller: A2uiProtocolController, surfaceId = "surface-1") {
  const surface = controller.getSurface("thread-1", surfaceId);
  expect(surface).toBeDefined();
  return surface!;
}

describe("stable JSON SHA-256", () => {
  it("matches standard vectors and recursively sorts object keys", () => {
    expect(sha256Utf8("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    expect(sha256Utf8("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    expect(stableJsonSha256({ z: 1, a: { y: 2, x: 3 } })).toBe(
      stableJsonSha256({ a: { x: 3, y: 2 }, z: 1 }),
    );
    expect(() => stableJsonSha256({ bad: Number.NaN })).toThrow(/JSON/);
    expect(() => stableJsonSha256({ bad: undefined })).toThrow(/JSON/);
  });
});

describe("strict envelope and v0.9-family validation", () => {
  it("accepts only the exact transport envelope and canonical catalog", () => {
    expect(validateA2uiEnvelope(envelope(1)).ok).toBe(true);
    expect(validateA2uiEnvelope(envelope(1, [
      { version: "v0.9", createSurface: { surfaceId: "s", catalogId: CATALOG } },
    ])).ok).toBe(true);

    expect(validateA2uiEnvelope(envelope(1, [
      { version: "v0.9.1", createSurface: {
        surfaceId: "s", catalogId: CATALOG_091, sendDataModel: false,
      } },
    ])).ok).toBe(true);

    const cases: unknown[] = [
      { ...envelope(1), transportVersion: 2 },
      { ...envelope(1), extra: true },
      { ...envelope(1), sequence: 0 },
      { ...envelope(1), eventId: "" },
      envelope(1, [{ version: "v1.0", createSurface: { surfaceId: "s" } }]),
      envelope(1, [{ version: "v0.9.1", createSurface: {
        surfaceId: "s", catalogId: CATALOG_091, sendDataModel: true,
      } }]),
      envelope(1, [{ version: "v0.9", createSurface: { surfaceId: "s", catalogId: `${CATALOG}/` } }]),
      envelope(1, [{ version: "v0.9", createSurface: { surfaceId: "s", catalogId: `${CATALOG}?x=1` } }]),
      envelope(1, [{ version: "v0.9", createSurface: { surfaceId: "s" }, deleteSurface: { surfaceId: "s" } }]),
      envelope(1, [{ version: "v0.9", madeUp: { surfaceId: "s" } }]),
      envelope(1, [{ version: "v0.9", updateDataModel: { surfaceId: "s", path: "relative", contents: 1 } }]),
      envelope(1, [{ version: "v0.9", updateDataModel: { surfaceId: "s", path: "/safe/~2bad", contents: 1 } }]),
      envelope(1, [{ version: "v0.9", updateDataModel: { surfaceId: "s", path: "/__proto__/x", contents: 1 } }]),
      envelope(1, [{ version: "v0.9", updateDataModel: { surfaceId: "s", path: "/constructor/x", contents: 1 } }]),
      envelope(1, [{ version: "v0.9", updateComponents: {
        surfaceId: "s", components: [{ id: "root", component: "Script" }],
      } }]),
      envelope(1, [{ version: "v0.9", updateComponents: {
        surfaceId: "s", components: [{ id: "root", component: "Script", children: { template: { componentId: "x", path: "/rows" } } }],
      } }]),
    ];
    for (const candidate of cases) expect(validateA2uiEnvelope(candidate).ok).toBe(false);
  });

  it("accepts standard child and direct template relative bindings", () => {
    const operations = [
      { version: "v0.9.1", createSurface: { surfaceId: "s", catalogId: CATALOG_091 } },
      { version: "v0.9.1", updateComponents: {
        surfaceId: "s",
        components: [
          { id: "root", component: "Card", child: "list" },
          { id: "list", component: "List", children: { componentId: "row", path: "/items" } },
          { id: "row", component: "Text", text: { path: "name" } },
        ],
      } },
      { version: "v0.9.1", updateDataModel: {
        surfaceId: "s", path: "/", value: { items: [{ name: "Ada" }] },
      } },
    ];
    expect(validateA2uiEnvelope(envelope(1, operations)).ok).toBe(true);
  });

  it("enforces operation, surface, component, string, depth, and envelope limits", () => {
    expect(validateA2uiEnvelope(envelope(1, Array.from({ length: A2UI_LIMITS.operations + 1 }, () => remove("x")))).ok).toBe(false);
    expect(validateA2uiEnvelope(envelope(1, [create(), root("surface-1", "x".repeat(A2UI_LIMITS.stringBytes + 1))])).ok).toBe(false);
    expect(validateA2uiEnvelope(envelope(1, [create(), {
      version: "v0.9", updateComponents: {
        surfaceId: "surface-1",
        components: Array.from({ length: A2UI_LIMITS.components + 1 }, (_, index) => ({
          id: index === 0 ? "root" : `c-${index}`, component: "Text", text: "x",
        })),
      },
    }])).ok).toBe(false);

    let nested: unknown = "leaf";
    for (let index = 0; index < A2UI_LIMITS.depth + 1; index++) nested = { nested };
    expect(validateA2uiEnvelope(envelope(1, [
      { version: "v0.9", updateDataModel: { surfaceId: "surface-1", path: "/", contents: nested } },
    ])).ok).toBe(false);

    const manySurfaces = Array.from({ length: A2UI_LIMITS.surfaces + 1 }, (_, index) => create(`s-${index}`));
    const controller = liveController();
    expect(controller.acceptEnvelope(envelope(1, manySurfaces)).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence ?? 0).toBe(0);

    const wide = Array.from({ length: 40 }, () => "x".repeat(8_000));
    expect(validateA2uiEnvelope(envelope(1, [{
      version: "v0.9", updateDataModel: { surfaceId: "surface-1", path: "/", contents: wide },
    }])).ok).toBe(false);
  });
});

describe("synchronous prepare and commit state machine", () => {
  it("uses the published 0.0.22 reducer, converter and snapshot functions by default", () => {
    upstreamSpies.reducer.mockClear();
    upstreamSpies.converter.mockClear();
    upstreamSpies.snapshot.mockClear();
    const controller = new A2uiProtocolController();
    controller.activateRun("thread-1", "run-1", "message-1");
    expect(controller.acceptEnvelope(envelope(1)).status).toBe("accepted");
    expect(upstreamSpies.reducer).toHaveBeenCalled();
    expect(upstreamSpies.converter).toHaveBeenCalledWith(expect.anything(), { keepUnknownComponents: false });
    expect(upstreamSpies.snapshot).toHaveBeenCalled();
  });

  it("accepts seq 1/2/3 in one tick and isolates threads", () => {
    const controller = liveController();
    expect(controller.acceptEnvelope(envelope(1)).status).toBe("accepted");
    expect(controller.acceptEnvelope(envelope(2)).status).toBe("accepted");
    expect(controller.acceptEnvelope(envelope(3)).status).toBe("accepted");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(3);
    expect(acceptedSurface(controller).revision).toBe(3);

    controller.activateRun("thread-2", "run-2", "message-2");
    expect(controller.acceptEnvelope(envelope(1, [create("surface-1"), root("surface-1", "other")], {
      threadId: "thread-2", runId: "run-2", eventId: "thread-2-event-1",
    })).status).toBe("accepted");
    expect(controller.getSurface("thread-2", "surface-1")?.part.spec).not.toEqual(
      controller.getSurface("thread-1", "surface-1")?.part.spec,
    );
    expect(controller.getThread("thread-2")?.lastAcceptedSequence).toBe(1);
  });

  it("deduplicates exact eventId+digest and fails closed on event/sequence conflict", () => {
    const controller = liveController();
    const first = envelope(1);
    expect(controller.acceptEnvelope(first).status).toBe("accepted");
    expect(controller.acceptEnvelope(first).status).toBe("duplicate");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(1);

    expect(controller.acceptEnvelope({ ...first, operations: [create("other")] }).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.mode).toBe("recovery-failed");

    const sequenceConflict = liveController();
    expect(sequenceConflict.acceptEnvelope(first).status).toBe("accepted");
    expect(sequenceConflict.acceptEnvelope({ ...first, eventId: "other-event" }).status).toBe("rejected");
    expect(sequenceConflict.getThread("thread-1")?.lastAcceptedSequence).toBe(1);
  });

  it("does not consume invalid batches or missing-surface updates", () => {
    const controller = liveController();
    const invalid = envelope(1, [{ version: "v1.0", deleteSurface: { surfaceId: "missing" } }]);
    expect(controller.acceptEnvelope(invalid).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence ?? 0).toBe(0);
    expect(controller.acceptEnvelope(envelope(1, [data(1, "missing")])).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence ?? 0).toBe(0);
  });

  it("enforces active run create preconditions while allowing later update/delete", () => {
    const controller = liveController();
    expect(controller.acceptEnvelope(envelope(1, [create()], { runId: "wrong" }))).toMatchObject({ status: "rejected" });
    expect(controller.getThread("thread-1")?.lastAcceptedSequence ?? 0).toBe(0);
    expect(controller.acceptEnvelope(envelope(1)).status).toBe("accepted");
    controller.closeRun("thread-1", "run-1");
    expect(controller.acceptEnvelope(envelope(2)).status).toBe("accepted");
    expect(controller.acceptEnvelope(envelope(3, [create("late")])).status).toBe("rejected");
    expect(controller.getSurface("thread-1", "late")).toBeUndefined();
  });

  it("rejects active duplicate create and allows delete-then-recreate", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    expect(acceptedSurface(controller)).toMatchObject({
      epoch: 1, revision: 1, anchor: { runId: "run-1", messageId: "message-1" },
    });
    expect(controller.acceptEnvelope(envelope(2, [create(), root("surface-1", "reset")], {
      eventId: "duplicate-create",
    })).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(1);
    expect(controller.acceptEnvelope(envelope(2, [remove()]))).toMatchObject({ status: "accepted" });
    expect(controller.getThread("thread-1")?.lineage.get("surface-1")).toMatchObject({
      epoch: 1, revision: 2, deletedAtSequence: 2,
    });
    expect(controller.acceptEnvelope(envelope(3, [create(), root("surface-1", "recreated")], {
      eventId: "recreate",
    })).status).toBe("accepted");
    expect(acceptedSurface(controller)).toMatchObject({
      epoch: 3, revision: 3, anchor: { runId: "run-1", messageId: "message-1" },
    });
  });

  it("increments each touched surface once per envelope using the envelope sequence", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1, [create(), root(), data(1), root("surface-1", "again")]));
    expect(acceptedSurface(controller)).toMatchObject({ epoch: 1, revision: 1 });
    controller.acceptEnvelope(envelope(2, [data(2), data(22)]));
    expect(acceptedSurface(controller).revision).toBe(2);
  });
});

describe("canonical parts, checkpoints, lineage, and hydrate", () => {
  it("generates canonical marker/snapshot/spec and hydrates from snapshot, not derived spec", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    const part = source.canonicalParts("thread-1")[0]!;
    expect(part).toMatchObject({
      type: "generative-ui",
      a2ui: {
        kind: "surface", schemaVersion: 1, transportVersion: 1,
        protocolVersion: "v0.9", surfaceId: "surface-1", epoch: 1, revision: 1,
      },
    });
    expect(part.a2ui.snapshot).toEqual(expect.arrayContaining([
      expect.objectContaining({ version: "v0.9", createSurface: expect.anything() }),
    ]));
    expect(part.spec).toMatchObject({ $type: "Markdown", value: "hello" });

    const restored = new A2uiProtocolController();
    const poisoned = { ...part, spec: { $type: "Image", src: "javascript:alert(1)" } } as CanonicalA2uiPart;
    expect(restored.hydrateThread("thread-1", [poisoned], source.exportCheckpoint("thread-1"), {
      authoritative: true,
    }).status).toBe("hydrated");
    expect(restored.getSurface("thread-1", "surface-1")?.part.spec).toMatchObject({
      $type: "Markdown", value: "hello",
    });
  });

  it("restores parts without an authoritative checkpoint as read-only/unconfirmed", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread("thread-1", source.canonicalParts("thread-1"), undefined, {
      authoritative: false,
    }).status).toBe("unconfirmed");
    expect(restored.getThread("thread-1")?.mode).toBe("unconfirmed");
    expect(restored.canDispatchAction("thread-1", "surface-1", 1, 1)).toBe(false);
    expect(restored.acceptEnvelope(envelope(2))).toMatchObject({ status: "rejected" });
  });

  it("keeps an independent checkpoint and tombstone through delete-all/reload/replay/recreate", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    source.acceptEnvelope(envelope(2, [remove()]));
    const checkpoint = source.exportCheckpoint("thread-1");
    expect(checkpoint).toMatchObject({ lastAcceptedSequence: 2, generation: 2 });
    expect(checkpoint?.lineage).toEqual(expect.arrayContaining([
      expect.objectContaining({ surfaceId: "surface-1", deletedAtSequence: 2 }),
    ]));
    expect(source.canonicalParts("thread-1")).toHaveLength(0);

    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread("thread-1", [], checkpoint, { authoritative: true }).status).toBe("hydrated");
    expect(restored.acceptEnvelope(envelope(1))).toMatchObject({ status: "duplicate" });
    restored.activateRun("thread-1", "run-2", "message-2");
    expect(restored.acceptEnvelope(envelope(3, [create(), root("surface-1", "recreated")], {
      runId: "run-2", eventId: "recreate",
    })).status).toBe("accepted");
    expect(restored.getSurface("thread-1", "surface-1")).toMatchObject({
      epoch: 3, revision: 3, anchor: { messageId: "message-2" },
    });
  });

  it("suppresses stale parts at or before a checkpoint tombstone", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    const stale = source.canonicalParts("thread-1")[0]!;
    source.acceptEnvelope(envelope(2, [remove()]));
    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread("thread-1", [stale], source.exportCheckpoint("thread-1"), {
      authoritative: true,
    }).status).toBe("hydrated");
    expect(restored.getSurface("thread-1", "surface-1")).toBeUndefined();
  });

  it("authoritatively replaces existing thread messages for delete-all hydrate", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    const stalePart = controller.canonicalParts("thread-1")[0]!;
    expect(controller.messageParts.size).toBe(1);
    controller.acceptEnvelope(envelope(2, [remove()]));
    const checkpoint = controller.exportCheckpoint("thread-1");

    // Reintroduce the prior canonical message to reproduce same-controller restore.
    controller.messageParts = new Map([["thread-1\u001fmessage-1\u001fsurface-1", stalePart]]);
    expect(controller.hydrateThread("thread-1", [], checkpoint, { authoritative: true }).status).toBe("hydrated");
    expect(controller.getThread("thread-1")?.surfaces.size).toBe(0);
    expect(controller.canonicalParts("thread-1")).toHaveLength(0);
    expect(controller.messageParts.size).toBe(0);
  });

  it("rejects stale or future parts against authoritative live checkpoint lineage", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    const stale = source.canonicalParts("thread-1")[0]!;
    source.acceptEnvelope(envelope(2));
    const checkpoint = source.exportCheckpoint("thread-1")!;

    const staleRestore = new A2uiProtocolController();
    expect(staleRestore.hydrateThread("thread-1", [stale], checkpoint, { authoritative: true }).status).toBe("recovery-failed");
    expect(staleRestore.getSurface("thread-1", "surface-1")).toBeUndefined();
    expect(staleRestore.canDispatchAction("thread-1", "surface-1", 1, 1)).toBe(false);

    const current = source.canonicalParts("thread-1")[0]!;
    for (const markerChanges of [
      { revision: checkpoint.lastAcceptedSequence + 1, lastSequence: checkpoint.lastAcceptedSequence + 1 },
      { lastSequence: checkpoint.lastAcceptedSequence + 1 },
    ]) {
      const future = { ...current, a2ui: { ...current.a2ui, ...markerChanges } };
      const restored = new A2uiProtocolController();
      expect(restored.hydrateThread("thread-1", [future], checkpoint, { authoritative: true }).status).toBe("recovery-failed");
      expect(restored.getSurface("thread-1", "surface-1")).toBeUndefined();
    }
  });

  it("treats missing authoritative checkpoints as unconfirmed without guessing sequence", () => {
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    source.acceptEnvelope(envelope(2, [data(2, "missing")]));
    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread("thread-1", source.canonicalParts("thread-1"), undefined, {
      authoritative: true,
    }).status).toBe("unconfirmed");
    expect(restored.getThread("thread-1")?.lastAcceptedSequence).toBe(0);
    expect(restored.canDispatchAction("thread-1", "surface-1", 1, 1)).toBe(false);
    expect(restored.acceptEnvelope(envelope(2))).toMatchObject({ status: "rejected" });

    const two = liveController();
    two.acceptEnvelope(envelope(1, [create("left"), root("left"), create("right"), root("right")]));
    two.acceptEnvelope(envelope(2, [remove("right")]));
    const partial = new A2uiProtocolController();
    expect(partial.hydrateThread("thread-1", two.canonicalParts("thread-1"), undefined, {
      authoritative: true,
    }).status).toBe("unconfirmed");
    expect(partial.getThread("thread-1")?.lastAcceptedSequence).toBe(0);
    expect(partial.getSurface("thread-1", "left")).toBeDefined();
    expect(partial.getSurface("thread-1", "right")).toBeUndefined();
    expect(partial.canDispatchAction("thread-1", "left", 1, 1)).toBe(false);
  });

  it("fails closed for every partial, wrong-version, or corrupt marker", () => {
    expect(classifyCanonicalPart({ type: "generative-ui", spec: {} })).toBe("legacy");
    for (const a2ui of [
      { kind: "surface" },
      { kind: "surface", schemaVersion: 2, transportVersion: 1, protocolVersion: "v0.9" },
      { kind: "surface", schemaVersion: 1, transportVersion: 2, protocolVersion: "v0.9" },
      { kind: "surface", schemaVersion: 1, transportVersion: 1, protocolVersion: "v1.0" },
    ]) {
      expect(classifyCanonicalPart({ type: "generative-ui", spec: {}, a2ui })).toBe("invalid");
    }
    const source = liveController();
    source.acceptEnvelope(envelope(1));
    const part = source.canonicalParts("thread-1")[0]!;
    expect(classifyCanonicalPart({
      ...part,
      a2ui: { ...part.a2ui, unexpected: "extension" },
    })).toBe("invalid");
    const corrupt = { ...part, a2ui: { ...part.a2ui, snapshotDigest: "0".repeat(64) } };
    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread("thread-1", [corrupt], source.exportCheckpoint("thread-1"), {
      authoritative: true,
    }).status).toBe("recovery-failed");
    expect(restored.canonicalParts("thread-1")).toHaveLength(0);
  });
});

describe("gap recovery", () => {
  it("keeps recovery message patches ordered for update then delete", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    const second = envelope(2, [data(2)]);
    const third = envelope(3, [remove()]);
    expect(controller.acceptEnvelope(third).status).toBe("recovery-requested");
    expect(controller.acceptRecovery({
      transportVersion: 1, threadId: "thread-1", fromSequence: 2, toSequence: 3,
      envelopes: [second, third],
    }).status).toBe("recovered");
    expect(controller.getSurface("thread-1", "surface-1")).toBeUndefined();
    expect(controller.canonicalParts("thread-1")).toHaveLength(0);
    expect([...controller.messageParts.values()].filter((part) => part.a2ui.surfaceId === "surface-1")).toHaveLength(0);
  });

  it("keeps only the latest incarnation for delete then recreate recovery", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    const second = envelope(2, [remove()]);
    const third = envelope(3, [create(), root("surface-1", "new")], { eventId: "recreate-3" });
    expect(controller.acceptEnvelope(third).status).toBe("recovery-requested");
    expect(controller.acceptRecovery({
      transportVersion: 1, threadId: "thread-1", fromSequence: 2, toSequence: 3,
      envelopes: [second, third],
    }).status).toBe("recovered");
    expect(controller.getSurface("thread-1", "surface-1")).toMatchObject({ epoch: 3, revision: 3 });
    const parts = [...controller.messageParts.values()].filter((part) => part.a2ui.surfaceId === "surface-1");
    expect(parts).toHaveLength(1);
    expect(parts[0]?.a2ui).toMatchObject({ epoch: 3, revision: 3 });
  });

  it("normalizes mixed multi-surface recovery in sequence order", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1, [
      create("left"), root("left", "old-left"), create("right"), root("right", "old-right"),
    ]));
    const second = envelope(2, [data(2, "left"), remove("right")]);
    const third = envelope(3, [remove("left"), create("right"), root("right", "new-right")]);
    const fourth = envelope(4, [data(4, "right")]);
    expect(controller.acceptEnvelope(fourth).status).toBe("recovery-requested");
    expect(controller.acceptRecovery({
      transportVersion: 1, threadId: "thread-1", fromSequence: 2, toSequence: 4,
      envelopes: [second, third, fourth],
    }).status).toBe("recovered");
    expect(controller.getSurface("thread-1", "left")).toBeUndefined();
    expect(controller.getSurface("thread-1", "right")).toMatchObject({ epoch: 3, revision: 4 });
    const parts = [...controller.messageParts.values()].filter((part) => part.a2ui.surfaceId === "left" || part.a2ui.surfaceId === "right");
    expect(parts).toHaveLength(1);
    expect(parts[0]?.a2ui).toMatchObject({ surfaceId: "right", epoch: 3, revision: 4 });
  });

  it("atomically applies the complete expected..N range including the rejected event exactly once", () => {
    let finalEventApplications = 0;
    const reducer: ProtocolDependencies["reducer"] = (state, operations) => {
      if (JSON.stringify(operations).includes("\"sequence\":3")) finalEventApplications++;
      return applyA2uiOperations(state, operations);
    };
    let now = 1_000;
    const controller = new A2uiProtocolController({ dependencies: { reducer }, now: () => now });
    controller.activateRun("thread-1", "run-1", "message-1");
    controller.acceptEnvelope(envelope(1));
    const second = envelope(2);
    const third = envelope(3);
    expect(controller.acceptEnvelope(third)).toMatchObject({
      status: "recovery-requested",
      recovery: { expectedSequence: 2, receivedSequence: 3, eventId: "event-3" },
    });
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(1);
    expect(controller.acceptEnvelope(second).status).toBe("rejected");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(1);

    expect(controller.acceptRecovery({
      transportVersion: 1,
      threadId: "thread-1",
      fromSequence: 2,
      toSequence: 3,
      envelopes: [second, third],
    }).status).toBe("recovered");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(3);
    expect(acceptedSurface(controller).revision).toBe(3);
    expect(finalEventApplications).toBe(1);
    now += 1;
  });

  it("fails atomically on incomplete/mismatched recovery and exposes failure/5s timeout APIs", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    controller.acceptEnvelope(envelope(3));
    expect(controller.acceptRecovery({
      transportVersion: 1, threadId: "thread-1", fromSequence: 2, toSequence: 3,
      envelopes: [envelope(3)],
    }).status).toBe("recovery-failed");
    expect(controller.getThread("thread-1")?.lastAcceptedSequence).toBe(1);
    expect(acceptedSurface(controller).revision).toBe(1);

    let now = 10;
    const timeout = new A2uiProtocolController({ now: () => now });
    timeout.activateRun("thread-1", "run-1", "message-1");
    timeout.acceptEnvelope(envelope(1));
    timeout.acceptEnvelope(envelope(3));
    now += A2UI_LIMITS.recoveryTimeoutMs;
    expect(timeout.checkRecoveryTimeouts()).toEqual(["thread-1"]);
    expect(timeout.getThread("thread-1")?.mode).toBe("recovery-failed");

    const explicit = liveController();
    explicit.acceptEnvelope(envelope(1));
    explicit.acceptEnvelope(envelope(3));
    explicit.failRecovery("thread-1", "ledger incomplete");
    expect(explicit.getThread("thread-1")?.failure).toMatch(/ledger incomplete/);
  });
});

describe("renderer safety and transactional fault containment", () => {
  it("filters dangerous Card CSS and Image URLs while retaining safe https/data images", () => {
    const controller = liveController();
    expect(controller.acceptEnvelope(envelope(1, [create(), {
      version: "v0.9", updateComponents: { surfaceId: "surface-1", components: [
        { id: "root", component: "Column", children: ["card", "bad", "good", "data"] },
        { id: "card", component: "Card", background: "url(javascript:evil)", padding: 4 },
        { id: "bad", component: "Image", src: "javascript:alert(1)", alt: "bad" },
        { id: "good", component: "Image", src: "https://example.com/a.png", alt: "good", size: 32 },
        { id: "data", component: "Image", src: "data:image/png;base64,iVBORw0KGgo=", alt: "data" },
      ] },
    }])).status).toBe("accepted");
    const spec = acceptedSurface(controller).part.spec as { children: Array<Record<string, unknown>> };
    expect(spec.children.find((node) => node.$type === "Card")).not.toHaveProperty("background");
    expect(spec.children.some((node) => node.src === "javascript:alert(1)")).toBe(false);
    expect(spec.children.some((node) => node.src === "https://example.com/a.png")).toBe(true);
    expect(spec.children.some((node) => String(node.src).startsWith("data:image/png"))).toBe(true);
  });

  it("rejects unsafe URL forms, malformed/oversized images, dimensions, spacing, and wide collections", () => {
    const oversizedBody = "QUJD".repeat(Math.ceil((A2UI_LIMITS.imageBytes + 1) / 3));
    const imageSources = [
      "https://user:password@example.com/a.png",
      "http://example.com/a.png",
      "data:image/svg+xml;base64,PHN2Zz4=",
      "file:///tmp/a.png",
      "blob:https://example.com/id",
      "data:image/png;base64,%%%not-base64%%%",
      `data:image/png;base64,${oversizedBody}`,
    ];
    for (const src of imageSources) expect(filterA2uiSpec({ $type: "Image", src }, "surface-1")).toBeNull();

    for (const size of [Number.NaN, Number.POSITIVE_INFINITY, -1, 15, 1025, Number.MAX_SAFE_INTEGER]) {
      expect(filterA2uiSpec({ $type: "Image", src: "https://example.com/a.png", alt: "safe", size }, "surface-1")).not.toHaveProperty("size");
    }
    for (const [type, key] of [["Row", "gap"], ["Col", "gap"], ["Card", "padding"]] as const) {
      for (const value of [Number.NaN, Number.POSITIVE_INFINITY, -1, 9, Number.MAX_SAFE_INTEGER]) {
        expect(filterA2uiSpec({ $type: type, [key]: value }, "surface-1")).not.toHaveProperty(key);
      }
    }
    const wide = Array.from({ length: A2UI_LIMITS.templateItems + 1 }, (_, index) => String(index));
    expect(filterA2uiSpec({ $type: "Select", options: wide }, "surface-1")).toBeNull();
    const children = filterA2uiSpec({
      $type: "Row",
      children: Array.from({ length: A2UI_LIMITS.templateItems + 10 }, (_, index) => ({ $type: "Text", value: String(index) })),
    }, "surface-1") as { children: unknown[] };
    expect(children.children).toHaveLength(A2UI_LIMITS.templateItems);
  });

  it("enforces required and optional runtime prop types after conversion", () => {
    for (const node of [
      { $type: "Header", text: { unsafe: true } },
      { $type: "Text", value: { unsafe: true } },
      { $type: "Caption", value: 42 },
      { $type: "Image", src: "https://example.com/a.png", alt: { unsafe: true } },
      { $type: "Button", label: ["unsafe"] },
      { $type: "Checkbox", label: false },
      { $type: "Markdown", value: { unsafe: true } },
      { $type: "Select", options: [{ label: "ok", value: 1 }] },
      { $type: "RadioGroup", options: [{ label: 1, value: "ok" }] },
    ]) expect(filterA2uiSpec(node, "surface-1")).toBeNull();

    const optional = filterA2uiSpec({
      $type: "Row", gap: 2, align: 1, justify: false,
      children: [
        { $type: "Divider", flush: "yes" },
        { $type: "Input", placeholder: 1, multiline: "yes", label: {}, name: [], defaultValue: "not-runtime" },
        { $type: "Checkbox", label: "choice", name: 1, defaultChecked: "yes" },
        { $type: "Button", label: "go", block: 1, submit: "yes" },
      ],
    }, "surface-1") as { align?: unknown; justify?: unknown; children: Array<Record<string, unknown>> };
    expect(optional).not.toHaveProperty("align");
    expect(optional).not.toHaveProperty("justify");
    expect(optional.children[0]).not.toHaveProperty("flush");
    expect(optional.children[1]).toEqual({ $type: "Input", defaultValue: "not-runtime" });
    expect(optional.children[2]).toEqual({ $type: "Checkbox", label: "choice" });
    expect(optional.children[3]).toEqual({ $type: "Button", label: "go" });
  });

  it("uses exact upstream enum, option, date, and image policy boundaries", () => {
    const valid = filterA2uiSpec({
      $type: "Row", gap: 8, align: "end", justify: "between",
      children: [
        { $type: "Header", text: "heading", size: "3xl" },
        { $type: "Text", value: "copy", size: "sm", weight: "bold", color: "white-70" },
        { $type: "Button", label: "go", buttonStyle: "danger", block: true, submit: false },
        { $type: "Image", src: "https://example.com/a.png", alt: "safe", size: "lg", round: true },
        { $type: "Icon", name: "arrow-up-right", size: "md" },
        { $type: "Select", options: [{ label: "One", value: "1" }], placeholder: "Pick", label: "choice", name: "choice" },
        { $type: "RadioGroup", options: [{ label: "One", value: "1" }], defaultValue: "1" },
        { $type: "DatePicker", value: "2024-02-29", min: "2024-01-01", max: "2024-12-31" },
      ],
    }, "surface-1") as { children: Array<Record<string, unknown>> };
    expect(valid).toMatchObject({ gap: 8, align: "end", justify: "between" });
    expect(valid.children[0]).toMatchObject({ size: "3xl" });
    expect(valid.children[1]).toMatchObject({ size: "sm", weight: "bold", color: "white-70" });
    expect(valid.children[2]).toMatchObject({ buttonStyle: "danger", block: true, submit: false });
    expect(valid.children[3]).toMatchObject({ size: "lg", round: true });
    expect(filterA2uiSpec({ $type: "Image", src: "https://example.com/a.png", alt: "safe", size: 16, round: "yes" }, "surface-1")).toEqual({
      $type: "Image", src: "https://example.com/a.png", alt: "safe", size: 16,
    });
    expect(filterA2uiSpec({ $type: "Image", src: "https://example.com/a.png", alt: "safe", size: 1024 }, "surface-1")).toMatchObject({ size: 1024 });
    expect(valid.children[4]).toMatchObject({ name: "arrow-up-right", size: "md" });
    expect(valid.children[5]?.options).toEqual([{ label: "One", value: "1" }]);
    expect(valid.children[7]).toMatchObject({ value: "2024-02-29" });

    const badEnums = [
      { $type: "Row", align: "evil", justify: "around" },
      { $type: "Col", align: "stretch" },
      { $type: "Button", label: "go", buttonStyle: "evil" },
      { $type: "Image", src: "https://example.com/a.png", alt: "safe", size: "xl" },
      { $type: "Text", value: "copy", size: "huge", weight: "heavy", color: "red" },
    ];
    for (const node of badEnums) {
      const filtered = filterA2uiSpec(node, "surface-1") as Record<string, unknown>;
      expect(filtered).not.toHaveProperty("align");
      expect(filtered).not.toHaveProperty("justify");
      expect(filtered).not.toHaveProperty("buttonStyle");
      expect(filtered).not.toHaveProperty("size");
      expect(filtered).not.toHaveProperty("weight");
      expect(filtered).not.toHaveProperty("color");
    }
    expect(filterA2uiSpec({ $type: "Icon", name: "evil" }, "surface-1")).toBeNull();
    expect(filterA2uiSpec({ $type: "DatePicker", value: "2023-02-29", min: "tomorrow" }, "surface-1")).toEqual({ $type: "DatePicker" });
    expect(filterA2uiSpec({ $type: "Select", options: [{ label: "One", value: "1", extra: true }] }, "surface-1")).toEqual({
      $type: "Select", options: [{ label: "One", value: "1" }],
    });
    const oversizedOptions = Array.from({ length: A2UI_LIMITS.templateItems + 1 }, () => ({ label: "x", value: "x" }));
    expect(filterA2uiSpec({ $type: "RadioGroup", options: oversizedOptions }, "surface-1")).toBeNull();
  });

  it("keeps the production protocol module browser-platform only", () => {
    expect(protocolSource).not.toMatch(/\bnode:/);
    expect(protocolSource).not.toMatch(/\bfrom\s*["']crypto["']/);
    expect(protocolSource).not.toMatch(/\bimport\s*\(\s*["']crypto["']/);
    expect(protocolSource).not.toMatch(/\brequire\s*\(/);
  });

  it("keeps controller, ledger, lineage, and messages unchanged when prepare faults mutate then throw", () => {
    const faultCases: Array<() => Partial<ProtocolDependencies>> = [
      () => ({ reducer: (state) => {
        state.get("surface-1")?.components.set("poison", { id: "poison", component: "Text" });
        throw new Error("reducer fault");
      } }),
      () => ({ converter: (surface) => {
        surface.components.set("poison", { id: "poison", component: "Text" });
        throw new Error("converter fault");
      } }),
      () => ({ filter: (spec) => {
        if (spec && typeof spec === "object") (spec as Record<string, unknown>).poison = true;
        throw new Error("filter fault");
      } }),
      () => ({ snapshot: (surface) => {
        surface.components.set("poison", { id: "poison", component: "Text" });
        throw new Error("snapshot fault");
      } }),
    ];
    for (const makeDependencies of faultCases) {
      const seed = liveController();
      seed.acceptEnvelope(envelope(1));
      const controller = new A2uiProtocolController({
        initialState: seed.state,
        dependencies: makeDependencies(),
      });
      controller.messageParts = seed.messageParts;
      expect(controller.acceptEnvelope(envelope(2)).status).toBe("rejected");
      const thread = controller.getThread("thread-1");
      expect(thread?.lastAcceptedSequence).toBe(1);
      expect(thread?.ledger).toHaveLength(1);
      expect(thread?.lineage.get("surface-1")?.revision).toBe(1);
      expect(thread?.surfaces.get("surface-1")?.surface.components.has("poison")).toBe(false);
      expect(controller.messageParts.values().next().value?.a2ui.revision).toBe(1);
    }
  });

  it("rolls back prepared controller and message inputs when patch mutates then throws", () => {
    const seed = liveController();
    seed.acceptEnvelope(envelope(1));
    const controller = new A2uiProtocolController({
      initialState: seed.state,
      patcher: (messages) => {
        const part = messages.values().next().value;
        if (part) (part.a2ui as { revision: number }).revision = 999;
        throw new Error("patch fault");
      },
    });
    controller.messageParts = seed.messageParts;
    expect(controller.acceptEnvelope(envelope(2)).status).toBe("recovery-failed");
    expect(controller.getThread("thread-1")).toMatchObject({
      lastAcceptedSequence: 1, mode: "recovery-failed",
    });
    expect(controller.getThread("thread-1")?.ledger).toHaveLength(1);
    expect(controller.getThread("thread-1")?.lineage.get("surface-1")?.revision).toBe(1);
    expect(controller.messageParts.values().next().value?.a2ui.revision).toBe(1);
  });

  it("exposes independent pure prepare, one-shot commit, and total patch functions", () => {
    let state = createControllerState();
    const bootstrap = new A2uiProtocolController({ initialState: state });
    bootstrap.activateRun("thread-1", "run-1", "message-1");
    state = bootstrap.state;
    const prepared = prepareEnvelopeTransaction(state, envelope(1));
    expect(prepared.status).toBe("prepared");
    if (prepared.status !== "prepared") return;
    const ref = { current: state };
    const committed = commitPreparedTransaction(ref, prepared, new Map(), applyMessagePatch);
    expect(committed.status).toBe("committed");
    expect(ref.current.threads.get("thread-1")?.lastAcceptedSequence).toBe(1);
    expect(committed.messages.size).toBeGreaterThan(0);
  });
});


it("normalizes accepted v0.9.1 wire operations to v0.9 canonical snapshots", () => {
  const controller = liveController();
  const operations = [
    { version: "v0.9.1", createSurface: { surfaceId: "surface-1", catalogId: CATALOG_091 } },
    { version: "v0.9.1", updateComponents: {
      surfaceId: "surface-1", components: [{ id: "root", component: "Text", text: "v091" }],
    } },
  ];
  expect(controller.acceptEnvelope(envelope(1, operations)).status).toBe("accepted");
  const snapshot = acceptedSurface(controller).part.a2ui.snapshot as Array<{ version?: unknown }>;
  expect(snapshot.every((operation) => operation.version === "v0.9")).toBe(true);
  expect(acceptedSurface(controller).part.a2ui.protocolVersion).toBe("v0.9");
});


describe("standard A2UI validation feedback", () => {
  it("reports only bounded rejected envelopes with known thread and surface identity", () => {
    expect(makeA2uiValidationFeedback(
      envelope(2, [{ version: "v0.9.1", updateComponents: {
        surfaceId: "surface-1",
        components: [{ id: "root", component: "Script" }],
      } }]),
      "Unknown A2UI component.",
      (threadId, surfaceId) => threadId === "thread-1" && surfaceId === "surface-1",
    )).toEqual({
      transportVersion: 1,
      threadId: "thread-1",
      version: "v0.9.1",
      error: {
        code: "VALIDATION_FAILED",
        surfaceId: "surface-1",
        path: "/operations",
        message: "A2UI envelope failed renderer validation.",
      },
    });
    expect(makeA2uiValidationFeedback({ bad: true }, "invalid", () => true)).toBeNull();
    expect(makeA2uiValidationFeedback(
      { ...envelope(1), threadId: "", operations: [create()] }, "invalid", () => true,
    )).toBeNull();
    expect(makeA2uiValidationFeedback(
      envelope(1, [data(1, "unknown-surface")]), "invalid", () => false,
    )).toBeNull();
  });
});


it("retains Slider and CheckboxGroup in the bounded fallback vocabulary", () => {
  expect(filterA2uiSpec({
    $type: "Slider", min: 0, max: 10, step: 1,
    defaultValue: 4, label: "Score", name: "/score",
  }, "surface-1")).toMatchObject({
    $type: "Slider", min: 0, max: 10, defaultValue: 4,
  });
  expect(filterA2uiSpec({
    $type: "CheckboxGroup",
    options: [{ label: "One", value: "1" }],
    defaultValue: ["1"], label: "Choices", name: "/choices",
  }, "surface-1")).toMatchObject({
    $type: "CheckboxGroup", defaultValue: ["1"],
  });
});


describe("A2UI present artifact history migration", () => {
  it("writes standard present artifacts and reads both formats from snapshot authority", () => {
    const controller = liveController();
    controller.acceptEnvelope(envelope(1));
    const legacy = controller.canonicalParts("thread-1")[0]!;
    const present = toPresentA2uiPart(legacy);
    expect(present).toMatchObject({
      type: "tool-call", toolCallId: "a2ui:surface-1", toolName: "present",
      result: {},
      artifact: {
        a2ui: expect.any(Array),
        shinyA2ui: { surfaceId: "surface-1", epoch: 1, revision: 1 },
      },
    });
    expect(classifyCanonicalPart(legacy)).toBe("valid");
    expect(classifyCanonicalPart(present)).toBe("valid");
    expect(getCanonicalA2uiMarker(present)).toMatchObject({ surfaceId: "surface-1" });
    expect(normalizeCanonicalA2uiPart(present)?.a2ui.snapshotDigest)
      .toBe(legacy.a2ui.snapshotDigest);

    const poisoned = { ...present, args: { $type: "Image", src: "javascript:alert(1)" } };
    const restored = new A2uiProtocolController();
    expect(restored.hydrateThread(
      "thread-1", [poisoned], controller.exportCheckpoint("thread-1"),
      { authoritative: true },
    ).status).toBe("hydrated");
    expect(restored.getSurface("thread-1", "surface-1")?.part.spec).toMatchObject({
      $type: "Markdown", value: "hello",
    });

    expect(classifyCanonicalPart({
      ...present,
      artifact: { ...present.artifact, a2ui: [remove("surface-1")] },
    })).toBe("invalid");
  });
});


describe("A2UI atomic snapshot replacement", () => {
  it("allows delete-create replacement of an existing surface after its run closes", () => {
    const controller = liveController();
    expect(controller.acceptEnvelope(envelope(1)).status).toBe("accepted");
    const original = acceptedSurface(controller);
    controller.closeRun("thread-1", "run-1");

    const result = controller.acceptEnvelope(envelope(2, [
      remove(), create(), root("surface-1", "activity replacement"),
    ], {
      runId: "background-activity",
      eventId: "activity-replace-2",
    }));
    expect(result.status).toBe("accepted");
    const replaced = acceptedSurface(controller);
    expect(replaced.part.spec).toMatchObject({
      $type: "Markdown", value: "activity replacement",
    });
    expect(replaced.anchor).toEqual(original.anchor);
    expect(replaced.epoch).toBe(2);

    expect(controller.acceptEnvelope(envelope(3, [create("new-surface")], {
      runId: "background-activity",
      eventId: "activity-new-3",
    })).status).toBe("rejected");
  });
});
