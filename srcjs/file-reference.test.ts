import { afterEach, describe, expect, it, vi } from "vitest";
import { createFileReferenceClient, type FileReferenceRequest } from "./file-reference";

afterEach(() => vi.useRealTimers());

describe("file reference confirmation", () => {
  const scope = { threadId: "history", project: "/project" };
  it("batches and deduplicates mounted references and caches confirmed and missing paths", () => {
    vi.useFakeTimers();
    const send = vi.fn<(request: FileReferenceRequest) => void>();
    const client = createFileReferenceClient(send);
    const listener = vi.fn();
    const off = client.subscribe(scope, "config.json", listener);
    const duplicate = client.subscribe(scope, "config.json", () => {});
    const missing = client.subscribe(scope, "missing.R", () => {});
    expect(client.getSnapshot(scope, "config.json")).toBeNull();
    expect(send).not.toHaveBeenCalled();
    vi.advanceTimersByTime(30);
    expect(send).toHaveBeenCalledOnce();
    const request = send.mock.calls[0][0];
    expect(request).toMatchObject({ version: 1, ...scope, paths: ["config.json", "missing.R"] });
    client.accept({ version: 1, requestId: request.requestId, threadId: scope.threadId, files: [
      { path: "config.json", resolvedPath: "/project/config.json" },
      { path: "missing.R", resolvedPath: null },
    ] });
    expect(client.getSnapshot(scope, "config.json")).toBe("/project/config.json");
    expect(client.getSnapshot(scope, "missing.R")).toBeNull();
    expect(listener).toHaveBeenCalledOnce();
    off(); duplicate(); missing();
    client.subscribe(scope, "missing.R", () => {})();
    vi.advanceTimersByTime(1000);
    expect(send).toHaveBeenCalledOnce();
    client.clear();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("limits each batch and permits only one in flight", () => {
    vi.useFakeTimers();
    const requests: FileReferenceRequest[] = [];
    const client = createFileReferenceClient((request) => requests.push(request));
    for (let i = 0; i < 70; i++) client.subscribe(scope, `file${i}.R`, () => {});
    vi.advanceTimersByTime(30);
    expect(requests).toHaveLength(1);
    expect(requests[0].paths).toHaveLength(32);
    for (let i = 0; i < 3; i++) {
      const request = requests[i];
      client.accept({ version: 1, requestId: request.requestId, threadId: scope.threadId,
        files: request.paths.map((path) => ({ path, resolvedPath: null })) });
      vi.advanceTimersByTime(30);
    }
    expect(requests.map((request) => request.paths.length)).toEqual([32, 32, 6]);
    client.clear();
  });

  it("isolates thread/project contexts and rejects stale and mismatched responses", () => {
    vi.useFakeTimers();
    const send = vi.fn<(request: FileReferenceRequest) => void>();
    const client = createFileReferenceClient(send);
    client.subscribe(scope, "config.json", () => {});
    vi.advanceTimersByTime(30);
    const first = send.mock.calls[0][0];
    const reply = { version: 1, requestId: first.requestId, threadId: scope.threadId,
      files: [{ path: "config.json", resolvedPath: "/project/config.json" }] };
    client.accept({ ...reply, threadId: "other" });
    expect(client.getSnapshot(scope, "config.json")).toBeNull();
    client.invalidate(scope.threadId);
    client.accept(reply);
    expect(client.getSnapshot(scope, "config.json")).toBeNull();
    vi.advanceTimersByTime(30);
    client.accept({ ...reply, requestId: send.mock.calls[1][0].requestId });
    expect(client.getSnapshot(scope, "config.json")).toBe("/project/config.json");
    expect(client.getSnapshot({ ...scope, threadId: "other" }, "config.json")).toBeNull();
    expect(client.getSnapshot({ ...scope, project: "/elsewhere" }, "config.json")).toBeNull();
    client.clear();
  });

  it("cancels unmounted checks and reports timeouts or malformed replies without enabling links", () => {
    vi.useFakeTimers();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const send = vi.fn<(request: FileReferenceRequest) => void>();
    const client = createFileReferenceClient(send);
    try {
      client.subscribe(scope, "unmounted.R", () => {})();
      vi.advanceTimersByTime(30);
      expect(send).not.toHaveBeenCalled();
      client.subscribe(scope, "timeout.R", () => {});
      vi.advanceTimersByTime(6000);
      expect(client.getSnapshot(scope, "timeout.R")).toBeNull();
      expect(warn).toHaveBeenCalledOnce();
      client.subscribe(scope, "invalid.R", () => {});
      vi.advanceTimersByTime(30);
      const request = send.mock.calls.at(-1)![0];
      client.accept({ version: 1, requestId: request.requestId, threadId: scope.threadId,
        files: [{ path: "unexpected.R", resolvedPath: "/project/invalid.R" }] });
      expect(client.getSnapshot(scope, "invalid.R")).toBeNull();
      expect(warn).toHaveBeenCalledTimes(2);
    } finally {
      client.clear();
      warn.mockRestore();
    }
  });

  it("retains last confirmed paths while refreshing but removes an explicit negative result", () => {
    vi.useFakeTimers();
    const send = vi.fn<(request: FileReferenceRequest) => void>();
    const client = createFileReferenceClient(send);
    client.subscribe(scope, "config.json", () => {});
    vi.advanceTimersByTime(30);
    client.accept({ version: 1, requestId: send.mock.calls[0][0].requestId, threadId: scope.threadId,
      files: [{ path: "config.json", resolvedPath: "/project/config.json" }] });
    client.invalidate(scope.threadId);
    expect(client.getSnapshot(scope, "config.json")).toBe("/project/config.json");
    vi.advanceTimersByTime(30);
    client.accept({ version: 1, requestId: send.mock.calls[1][0].requestId, threadId: scope.threadId,
      files: [{ path: "config.json", resolvedPath: null }] });
    expect(client.getSnapshot(scope, "config.json")).toBeNull();
    client.clear();
  });

  it("does not make a newly active thread wait for an abandoned in-flight batch", () => {
    vi.useFakeTimers();
    const send = vi.fn<(request: FileReferenceRequest) => void>();
    const client = createFileReferenceClient(send);
    const leave = client.subscribe(scope, "old.R", () => {});
    vi.advanceTimersByTime(30);
    const old = send.mock.calls[0][0];
    leave();
    const next = { threadId: "next", project: "/other" };
    client.subscribe(next, "new.R", () => {});
    vi.advanceTimersByTime(30);
    expect(send).toHaveBeenCalledTimes(2);
    client.accept({ version: 1, requestId: old.requestId, threadId: scope.threadId,
      files: [{ path: "old.R", resolvedPath: "/project/old.R" }] });
    expect(client.getSnapshot(next, "new.R")).toBeNull();
    client.clear();
  });
});
