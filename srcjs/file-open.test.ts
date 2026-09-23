import { afterEach, describe, expect, it, vi } from "vitest";
import { createFileOpenClient, type FileOpenRequest } from "./file-open";

afterEach(() => vi.useRealTimers());

describe("file opening acknowledgements", () => {
  const scope = { threadId: "history", project: "/project" };
  it("coalesces pending duplicates and waits for the matching backend outcome", async () => {
    const send = vi.fn<(request: FileOpenRequest) => void>();
    const client = createFileOpenClient(send);
    const first = client.open("/project/file.R", 7, scope);
    expect(client.open("/project/file.R", 7, scope)).toBe(first);
    expect(send).toHaveBeenCalledOnce();
    const request = send.mock.calls[0][0];
    let settled = false;
    void first.then(() => { settled = true; });
    client.accept({ version: 1, requestId: request.requestId, threadId: "wrong", ok: true });
    await Promise.resolve();
    expect(settled).toBe(false);
    client.accept({ version: 1, requestId: request.requestId, threadId: "history", ok: false });
    await expect(first).resolves.toBe(false);
    const retry = client.open("/project/file.R", 7, scope);
    expect(send).toHaveBeenCalledTimes(2);
    client.accept({ version: 1, requestId: send.mock.calls[1][0].requestId, threadId: "history", ok: true });
    await expect(retry).resolves.toBe(true);
    client.clear();
  });

  it("keeps different lines and contexts independent and settles all waiters on teardown", async () => {
    const send = vi.fn<(request: FileOpenRequest) => void>();
    const client = createFileOpenClient(send);
    const pending = [
      client.open("/project/file.R", 1, scope),
      client.open("/project/file.R", 2, scope),
      client.open("/project/file.R", 1, { ...scope, threadId: "other" }),
    ];
    expect(send).toHaveBeenCalledTimes(3);
    client.clear();
    await expect(Promise.all(pending)).resolves.toEqual([false, false, false]);
    client.accept({ version: 1, requestId: send.mock.calls[0][0].requestId, threadId: "history", ok: true });
  });

  it("reports an unacknowledged or unsent open as failed without replaying it", async () => {
    vi.useFakeTimers();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const send = vi.fn<(request: FileOpenRequest) => void>();
    const client = createFileOpenClient(send);
    try {
      const pending = client.open("/project/file.R", undefined, scope);
      await vi.advanceTimersByTimeAsync(10000);
      await expect(pending).resolves.toBe(false);
      expect(send).toHaveBeenCalledOnce();
      expect(warn).toHaveBeenCalledOnce();
      send.mockImplementationOnce(() => { throw new Error("Synthetic transport failure"); });
      await expect(client.open("/project/file.R", undefined, scope)).resolves.toBe(false);
      expect(warn).toHaveBeenCalledTimes(2);
    } finally {
      client.clear();
      warn.mockRestore();
    }
  });
});
