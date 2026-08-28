import { describe, expect, it, vi } from "vitest";
import {
  createLazyToolResultClient,
  isLazyToolResultDescriptor,
  type LazyToolResultDescriptor,
} from "./lazy-tool-result";

const descriptor: LazyToolResultDescriptor = {
  kind: "lazy-tool-result",
  version: 1,
  handle: "handle-a",
  generation: 4,
  threadId: "thread-a",
  toolCallId: "tool-a",
  originalBytes: 30,
  sourceBytes: 300,
  truncated: true,
  chunkBytes: 10,
  summary: "30 byte bounded preview of 300 byte result",
};

describe("lazy tool result client", () => {
  it("recognizes only the versioned bounded descriptor", () => {
    expect(isLazyToolResultDescriptor(descriptor)).toBe(true);
    expect(isLazyToolResultDescriptor({ ...descriptor, version: 2 })).toBe(false);
    expect(isLazyToolResultDescriptor({ ...descriptor, originalBytes: -1 })).toBe(false);
    expect(isLazyToolResultDescriptor({ ...descriptor, sourceBytes: 20 })).toBe(false);
    expect(isLazyToolResultDescriptor({ ...descriptor, truncated: "yes" })).toBe(false);
    expect(isLazyToolResultDescriptor("full body")).toBe(false);
  });

  it("does not request while collapsed and deduplicates an in-flight opening request", () => {
    const send = vi.fn();
    const client = createLazyToolResultClient(send, { retainedBytes: 20 });

    expect(client.getSnapshot(descriptor).text).toBe("");
    expect(send).not.toHaveBeenCalled();
    client.open(descriptor, "thread-a", "tool-a");
    client.open(descriptor, "thread-a", "tool-a");

    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls[0][0]).toMatchObject({
      handle: "handle-a", generation: 4, threadId: "thread-a", toolCallId: "tool-a",
      offset: 0, maxBytes: 10,
    });
  });

  it("loads continuously, ignores duplicate near-bottom requests, and rejects stale replies", () => {
    const send = vi.fn();
    const client = createLazyToolResultClient(send, { retainedBytes: 20 });
    client.open(descriptor, "thread-a", "tool-a");
    const first = send.mock.calls[0][0];

    client.accept({
      ...first, text: "0123456789", nextOffset: 10, done: false,
    });
    expect(client.getSnapshot(descriptor).text).toBe("0123456789");

    client.requestNext(descriptor, "thread-a", "tool-a");
    client.requestNext(descriptor, "thread-a", "tool-a");
    expect(send).toHaveBeenCalledTimes(2);
    const second = send.mock.calls[1][0];

    client.accept({ ...second, requestId: "stale", text: "BAD", nextOffset: 13, done: false });
    expect(client.getSnapshot(descriptor).text).toBe("0123456789");
    client.accept({ ...second, generation: 3, text: "BAD", nextOffset: 13, done: false });
    expect(client.getSnapshot(descriptor).text).toBe("0123456789");
    client.accept({ ...second, text: "abcdefghij", nextOffset: 20, done: false });
    expect(client.getSnapshot(descriptor).text).toBe("0123456789abcdefghij");
  });

  it("evicts old chunks under the retained byte budget and ignores replies after collapse", () => {
    const send = vi.fn();
    const client = createLazyToolResultClient(send, { retainedBytes: 12 });
    client.open(descriptor, "thread-a", "tool-a");
    const first = send.mock.calls[0][0];
    client.accept({ ...first, text: "0123456789", nextOffset: 10, done: false });
    client.requestNext(descriptor, "thread-a", "tool-a");
    const second = send.mock.calls[1][0];
    client.accept({ ...second, text: "abcdefghij", nextOffset: 20, done: false });

    const snapshot = client.getSnapshot(descriptor);
    expect(snapshot.retainedBytes).toBeLessThanOrEqual(12);
    expect(snapshot.droppedBytes).toBeGreaterThan(0);
    expect(snapshot.text).not.toContain("0123456789");

    client.requestNext(descriptor, "thread-a", "tool-a");
    const third = send.mock.calls[2][0];
    client.close(descriptor);
    client.accept({ ...third, text: "STALE", nextOffset: 25, done: false });
    expect(client.getSnapshot(descriptor).text).toBe("");
  });

  it("bounds even one oversized UTF-8 chunk", () => {
    const send = vi.fn();
    const client = createLazyToolResultClient(send, { retainedBytes: 8 });
    const utf8Descriptor = { ...descriptor, originalBytes: 20, chunkBytes: 20 };
    client.open(utf8Descriptor, "thread-a", "tool-a");
    const request = send.mock.calls[0][0];
    client.accept({
      ...request,
      text: "界界界界界界",
      nextOffset: 18,
      done: false,
    });
    const snapshot = client.getSnapshot(utf8Descriptor);
    expect(snapshot.retainedBytes).toBeLessThanOrEqual(8);
    expect(snapshot.droppedBytes).toBeGreaterThan(0);
    expect(new TextEncoder().encode(snapshot.text).byteLength).toBe(snapshot.retainedBytes);
  });
});
