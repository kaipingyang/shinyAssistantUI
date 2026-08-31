import { describe, it, expect, beforeEach, vi } from "vitest";
import { createShinyBridge } from "./bridge";
import type { RunCallbacks } from "./bridge";

// mock 全局 Shiny：记录 setInputValue 调用 + 捕获注册的 customMessageHandler
type Handler = (data: unknown) => void;
let handlers: Record<string, Handler>;
let inputValues: Array<{ id: string; value: unknown }>;

beforeEach(() => {
  handlers = {};
  inputValues = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (globalThis as any).Shiny = {
    setInputValue: (id: string, value: unknown) => inputValues.push({ id, value }),
    addCustomMessageHandler: (type: string, h: Handler) => { handlers[type] = h; },
  };
});

function mkCallbacks(): RunCallbacks & { calls: Record<string, unknown[]> } {
  const calls: Record<string, unknown[]> = {};
  const rec = (k: string) => (...args: unknown[]) => { (calls[k] ??= []).push(args); };
  return {
    calls,
    onChunk: rec("chunk"), onThinking: rec("thinking"),
    onToolCall: rec("toolCall"), onToolCallStart: rec("toolCallStart"),
    onToolCallDelta: rec("toolCallDelta"), onToolResult: rec("toolResult"),
    onAutoContinue: rec("autoContinue"),
    onDone: rec("done"), onError: rec("error"),
  };
}

describe("bridge 多线程路由", () => {
  it("按 threadId 路由到对应回调", () => {
    const b = createShinyBridge("chat");
    const cbA = mkCallbacks();
    const cbB = mkCallbacks();
    b.setRunCallbacks("tA", cbA);
    b.setRunCallbacks("tB", cbB);

    handlers["chat:chunk"]({ text: "hello", threadId: "tA" });
    expect(cbA.calls.chunk).toEqual([["hello"]]);
    expect(cbB.calls.chunk).toBeUndefined();

    handlers["chat:chunk"]({ text: "world", threadId: "tB" });
    expect(cbB.calls.chunk).toEqual([["world"]]);
  });

  it("缺 threadId 单线程回退唯一回调", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("tA", cb);
    handlers["chat:chunk"]({ text: "x" }); // 无 threadId
    expect(cb.calls.chunk).toEqual([["x"]]);
  });

  it("缺 threadId 多线程时放弃（不串台）+ warn", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const b = createShinyBridge("chat");
    const cbA = mkCallbacks();
    const cbB = mkCallbacks();
    b.setRunCallbacks("tA", cbA);
    b.setRunCallbacks("tB", cbB);
    handlers["chat:chunk"]({ text: "x" }); // 无 threadId，2 个线程
    expect(cbA.calls.chunk).toBeUndefined();
    expect(cbB.calls.chunk).toBeUndefined();
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });

  it("setRunCallbacks(null) 只删自己，不影响其它线程", () => {
    const b = createShinyBridge("chat");
    const cbA = mkCallbacks();
    const cbB = mkCallbacks();
    b.setRunCallbacks("tA", cbA);
    b.setRunCallbacks("tB", cbB);
    b.setRunCallbacks("tA", null); // 删 A
    handlers["chat:chunk"]({ text: "x", threadId: "tB" });
    expect(cbB.calls.chunk).toEqual([["x"]]); // B 仍工作
    handlers["chat:chunk"]({ text: "y", threadId: "tA" });
    expect(cbA.calls.chunk).toBeUndefined(); // A 已删
  });

  it("未知 threadId 不崩（可选链）", () => {
    const b = createShinyBridge("chat");
    expect(() => handlers["chat:chunk"]({ text: "x", threadId: "ghost" })).not.toThrow();
  });

  it("tool-call-start/delta 路由 + 可选回调", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("t1", cb);
    handlers["chat:tool-call-start"]({ toolCallId: "tc1", toolName: "bash", threadId: "t1" });
    handlers["chat:tool-call-delta"]({ toolCallId: "tc1", delta: "{\"a", threadId: "t1" });
    expect(cb.calls.toolCallStart).toEqual([["tc1", "bash", undefined]]);
    expect(cb.calls.toolCallDelta).toEqual([["tc1", "{\"a"]]);
  });

  it("tool-result isError 默认 false", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("t1", cb);

    handlers["chat:tool-result"]({ toolCallId: "tc1", result: "ok", threadId: "t1" });
    expect(cb.calls.toolResult).toEqual([["tc1", "ok", false]]);
  });

  it("sendRunInConsole 发出 _run_in_console 事件（code）", () => {
    const b = createShinyBridge("chat");
    b.sendRunInConsole("plot(1:10)");
    const evt = inputValues.filter((v) => v.id === "chat_run_in_console").at(-1);
    expect(evt).toBeTruthy();
    expect(evt!.value).toMatchObject({ code: "plot(1:10)" });
  });

  it("sendOpenFile 发出 _open_file 事件（path + line）", () => {
    const b = createShinyBridge("chat");
    b.sendOpenFile("R/app.R", 12);
    const evt = inputValues.find((v) => v.id === "chat_open_file");
    expect(evt).toBeTruthy();
    expect(evt!.value).toMatchObject({ path: "R/app.R", line: 12 });

    b.sendOpenFile("R/util.R");
    const evt2 = inputValues.filter((v) => v.id === "chat_open_file").at(-1);
    expect(evt2!.value).toMatchObject({ path: "R/util.R", line: null });
  });

  it("sendArchiveSession / sendDeleteSession 发出对应事件（方案B）", () => {
    const b = createShinyBridge("chat");
    b.sendArchiveSession("sess-1", true);
    const arc = inputValues.find((v) => v.id === "chat_archive_session");
    expect(arc!.value).toMatchObject({ sessionId: "sess-1", archived: true });

    b.sendArchiveSession("sess-1", false);
    const unarc = inputValues.filter((v) => v.id === "chat_archive_session").at(-1);
    expect(unarc!.value).toMatchObject({ sessionId: "sess-1", archived: false });

    b.sendDeleteSession("sess-2");
    const del = inputValues.find((v) => v.id === "chat_delete_session");
    expect(del!.value).toMatchObject({ sessionId: "sess-2" });
  });
});

describe("bridge inputId 前缀隔离（多 widget）", () => {
  it("两个 widget 注册独立前缀 handler，互不干扰", () => {
    const bA = createShinyBridge("chatA");
    const bB = createShinyBridge("chatB");
    const cbA = mkCallbacks();
    const cbB = mkCallbacks();
    bA.setRunCallbacks("t", cbA);
    bB.setRunCallbacks("t", cbB);
    // 同 threadId "t" 但不同 inputId 前缀
    handlers["chatA:chunk"]({ text: "A", threadId: "t" });
    handlers["chatB:chunk"]({ text: "B", threadId: "t" });
    expect(cbA.calls.chunk).toEqual([["A"]]);
    expect(cbB.calls.chunk).toEqual([["B"]]);
  });
});

describe("bridge sessions 缓冲回放", () => {
  it("handler 注册前到达的 :sessions 被缓冲，注册时回放", () => {
    const b = createShinyBridge("chat");
    handlers["chat:sessions"]({
      sessions: [{ id: "s1", title: "t", preview: "p", createdAt: "2026" }],
      projectOrder: ["/work/c", "/work/a"],
    });
    const received: Array<{ projectOrder?: string[] }> = [];
    b.onSessions((d) => received.push(d));
    expect(received).toHaveLength(1);
    expect(received[0]?.projectOrder).toEqual(["/work/c", "/work/a"]);
  });

  it("handler 已注册则直接调用不缓冲", () => {
    const b = createShinyBridge("chat");
    const received: unknown[] = [];
    b.onSessions((d) => received.push(d));
    handlers["chat:sessions"]({ sessions: [] });
    expect(received).toHaveLength(1);
  });
});

describe("bridge 出站消息", () => {
  it("sendUserMessage 带 threadId + attachments", () => {
    const b = createShinyBridge("chat");
    b.sendUserMessage("hi", "t1", [{ type: "text", name: "a", data: "x" }]);
    expect(inputValues[0].id).toBe("chat");
    const v = inputValues[0].value as { text: string; threadId: string; attachments: unknown[] };
    expect(v.text).toBe("hi");
    expect(v.threadId).toBe("t1");
    expect(v.attachments).toHaveLength(1);
  });

  it("sendCancel 发到 _cancel 子 input with matching runId", () => {
    const b = createShinyBridge("chat");
    b.sendCancel("t1", "run-1");
    expect(inputValues[0].id).toBe("chat_cancel");
    expect(inputValues[0].value).toMatchObject({ threadId: "t1", runId: "run-1" });
  });


  it("sendUserMessage carries hidden continuation kind without changing visible text", () => {
    const b = createShinyBridge("chat");
    b.sendUserMessage(
      "继续", "t1", undefined, undefined, undefined,
      "run-minimal", undefined, undefined, "minimal",
    );
    expect(inputValues[0]).toMatchObject({ id: "chat" });
    expect(inputValues[0].value).toMatchObject({
      text: "继续", threadId: "t1", runId: "run-minimal", continuationKind: "minimal",
    });
  });

  it("routes a valid hidden auto-continuation kind", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("t1", cb);
    handlers["chat:auto-continue"]({
      threadId: "t1", runId: "run-1", notice: "retry", prompt: "继续", kind: "minimal",
    });
    expect(cb.calls.autoContinue).toEqual([[
      expect.objectContaining({ prompt: "继续", kind: "minimal" }),
    ]]);
  });

  it("sendToolApproval 带 toolCallId + approved", () => {
    const b = createShinyBridge("chat");
    b.sendToolApproval("tc1", true, { suggestionIdx: 2 });
    expect(inputValues[0].id).toBe("chat_tool_approval");
    const v = inputValues[0].value as { toolCallId: string; approved: boolean; suggestionIdx: number };
    expect(v.toolCallId).toBe("tc1");
    expect(v.approved).toBe(true);
    expect(v.suggestionIdx).toBe(2);
  });
});


describe("bridge action correlation", () => {
  it("sendAction sends requestId and silent metadata", () => {
    const b = createShinyBridge("chat");
    b.sendAction("permissions:plan", "t1", { requestId: "req-1", silent: true });
    expect(inputValues[0].id).toBe("chat_action");
    expect(inputValues[0].value).toMatchObject({
      id: "permissions:plan", threadId: "t1", requestId: "req-1", silent: true,
    });
  });

  it("action-result preserves correlation and canonical value", () => {
    const b = createShinyBridge("chat");
    const received: unknown[] = [];
    b.onActionResult((d) => received.push(d));
    handlers["chat:action-result"]({
      threadId: "t1", requestId: "req-1", actionId: "permissions:plan",
      status: "ok", message: "submitted", value: "plan",
    });
    expect(received).toEqual([expect.objectContaining({
      requestId: "req-1", actionId: "permissions:plan", value: "plan",
    })]);
  });
});


describe("bridge IDE context and workspace search", () => {
  it("sendUserMessage carries only selection visibility policy", () => {
    const b = createShinyBridge("chat");
    b.sendUserMessage("explain", "t1", undefined, { selectionVisible: false });
    expect(inputValues[0]).toMatchObject({ id: "chat" });
    expect(inputValues[0].value).toMatchObject({
      text: "explain", threadId: "t1", ideContext: { selectionVisible: false },
    });
    expect(JSON.stringify(inputValues[0].value)).not.toContain("selectionText");
  });

  it("refresh and search remain inputId/request/thread correlated", () => {
    const b = createShinyBridge("chat");
    const contexts: unknown[] = [];
    const results: unknown[] = [];
    b.onIdeContext((value) => contexts.push(value));
    b.onWorkspaceResults((value) => results.push(value));
    b.requestIdeContext("ctx-1", "t1");
    b.searchWorkspace("ws-1", "t1", "app", ["file", "folder"], 20);

    expect(inputValues[0]).toMatchObject({ id: "chat_ide_context_refresh" });
    expect(inputValues[0].value).toMatchObject({ requestId: "ctx-1", threadId: "t1" });
    expect(inputValues[1]).toMatchObject({ id: "chat_workspace_search" });
    expect(inputValues[1].value).toMatchObject({
      requestId: "ws-1", threadId: "t1", query: "app", kinds: ["file", "folder"], limit: 20,
    });

    handlers["chat:ide-context"]({ requestId: "ctx-1", threadId: "t1", relativePath: "R/app.R" });
    handlers["chat:workspace-results"]({ requestId: "ws-1", threadId: "t1", items: [] });
    expect(contexts).toHaveLength(1);
    expect(results).toHaveLength(1);
  });
});


describe("bridge run correlation", () => {
  it("forwards runId on terminal messages and reservation inputs", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("t1", cb);
    handlers["chat:done"]({ threadId: "t1", runId: "run-1", cancelled: true });
    handlers["chat:error"]({ threadId: "t1", runId: "run-2", message: "bad" });
    expect(cb.calls.done).toEqual([[undefined, "run-1", true]]);
    expect(cb.calls.error).toEqual([["bad", "run-2"]]);

    b.reserveIdeContext("submission-1", "t1", true);
    b.cancelReservedSubmissions(["submission-1"]);
    expect(inputValues.find((value) => value.id === "chat_reserve_submission")?.value)
      .toMatchObject({ submissionId: "submission-1", threadId: "t1", selectionVisible: true });
    expect(inputValues.find((value) => value.id === "chat_cancel_reserved_submissions")?.value)
      .toMatchObject({ submissionIds: ["submission-1"] });
  });
});


describe("bridge authoritative run-state", () => {
  it("routes additive queued/connecting/running/terminal payloads without run callbacks", () => {
    const bridge = createShinyBridge("chat");
    const received: unknown[] = [];
    bridge.onRunState((value) => received.push(value));

    handlers["chat:run-state"]({
      threadId: "A", runId: "run-A", phase: "queued", queuePosition: 1,
    });
    handlers["chat:run-state"]({
      threadId: "A", runId: "run-A", phase: "running",
    });

    expect(received).toEqual([
      expect.objectContaining({ threadId: "A", runId: "run-A", phase: "queued", queuePosition: 1 }),
      expect.objectContaining({ threadId: "A", runId: "run-A", phase: "running" }),
    ]);
  });
});


describe("bridge workspace project snapshots", () => {
  it("adds an optional project to project-sensitive requests", () => {
    const b = createShinyBridge("chat");
    b.sendUserMessage("hi", "t1", undefined, undefined, undefined, undefined, undefined, "/work/a");
    b.reserveIdeContext("sub-1", "t1", true, "/work/a");
    b.sendRename("t1", "Renamed", "/work/a");
    b.sendArchiveSession("t1", true, "/work/a");
    b.sendDeleteSession("t1", "/work/a");
    b.sendLoadSession("t1", "t1", "load-1", "/work/a");
    b.sendLoadSessionPage("t1", "t1", 2, 50, "page-1", "/work/a");
    b.requestIdeContext("ctx-1", "t1", "/work/a");
    b.searchWorkspace("ws-1", "t1", "app", ["file"], 10, "/work/a");

    for (const event of inputValues) {
      expect(event.value).toMatchObject({ project: "/work/a" });
    }
  });

  it("keeps ordinary requests backward compatible when project is absent", () => {
    const b = createShinyBridge("chat");
    b.sendUserMessage("hi", "t1");
    b.sendLoadSession("t1", "t1");
    expect(inputValues.every((event) => !("project" in (event.value as Record<string, unknown>))))
      .toBe(true);
  });
});


describe("bridge Workspace project snapshots", () => {
  it("forwards project on warmup, action, reload, open-file, and console events", () => {
    const b = createShinyBridge("chat");
    b.sendWarmup("thread-a", "/work/a");
    b.sendAction("context", "thread-a", { requestId: "request-a" }, "/work/a");
    b.sendReload("again", "thread-a", "run-a", "/work/a");
    b.sendOpenFile("R/app.R", 12, "thread-a", "/work/a");
    b.sendRunInConsole("getwd()", "thread-a", "/work/a");

    expect(inputValues.find((item) => item.id === "chat_warmup")?.value)
      .toMatchObject({ threadId: "thread-a", project: "/work/a" });
    expect(inputValues.find((item) => item.id === "chat_action")?.value)
      .toMatchObject({ threadId: "thread-a", project: "/work/a" });
    expect(inputValues.find((item) => item.id === "chat")?.value)
      .toMatchObject({ type: "reload", threadId: "thread-a", project: "/work/a" });
    expect(inputValues.find((item) => item.id === "chat_open_file")?.value)
      .toMatchObject({ threadId: "thread-a", project: "/work/a" });
    expect(inputValues.find((item) => item.id === "chat_run_in_console")?.value)
      .toMatchObject({ threadId: "thread-a", project: "/work/a" });
  });
});


describe("assistant text size bridge", () => {
  it("sends the selected enum through the widget-specific input", () => {
    const bridge = createShinyBridge("chat");
    bridge.sendAssistantTextSize("small");
    const event = inputValues.find((item) => item.id === "chat_assistant_text_size");
    expect(event).toBeTruthy();
    expect(event!.value).toMatchObject({ value: "small" });
  });
});


describe("bridge transparent auto-continuation", () => {
  it("routes the visible notice and prompt to the owning run", () => {
    const b = createShinyBridge("chat");
    const cb = mkCallbacks();
    b.setRunCallbacks("t1", cb);
    handlers["chat:auto-continue"]({
      threadId: "t1",
      runId: "run-1",
      notice: "Continuing automatically…",
      prompt: "Please continue from the completed tool results.",
    });
    expect(cb.calls.autoContinue).toEqual([[
      {
        threadId: "t1",
        runId: "run-1",
        notice: "Continuing automatically…",
        prompt: "Please continue from the completed tool results.",
      },
    ]]);
  });
});


describe("bridge proactive-messages global subscription", () => {
  const snapshot = (threadId: string, revision: number, id: string) => ({
    version: 1,
    operation: "replace",
    threadId,
    revision,
    messages: [
      { id, role: "assistant", content: [{ type: "text", text: id }] },
    ],
  });

  it("buffers every early payload FIFO until the global subscriber registers", () => {
    const bridge = createShinyBridge("chat");
    const first = snapshot("thread-a", 1, "first");
    const second = snapshot("thread-a", 2, "second");

    handlers["chat:proactive-messages"](first);
    handlers["chat:proactive-messages"](second);

    const received: unknown[] = [];
    bridge.onProactiveMessages((payload) => received.push(payload));

    expect(received).toEqual([first, second]);
  });

  it("keeps early queues and subscribers isolated by widget inputId", () => {
    const bridgeA = createShinyBridge("chatA");
    const bridgeB = createShinyBridge("chatB");
    const payloadA = snapshot("shared-thread", 1, "widget-a");
    const payloadB = snapshot("shared-thread", 1, "widget-b");

    handlers["chatA:proactive-messages"](payloadA);
    handlers["chatB:proactive-messages"](payloadB);

    const receivedA: unknown[] = [];
    const receivedB: unknown[] = [];
    bridgeA.onProactiveMessages((payload) => receivedA.push(payload));
    bridgeB.onProactiveMessages((payload) => receivedB.push(payload));

    expect(receivedA).toEqual([payloadA]);
    expect(receivedB).toEqual([payloadB]);

    handlers["chatA:proactive-messages"](snapshot("shared-thread", 2, "widget-a-live"));
    expect(receivedA).toHaveLength(2);
    expect(receivedB).toEqual([payloadB]);
  });
});


describe("Claude edit marker settings bridge", () => {
  it("sends the selected boolean through the widget-specific input", () => {
    const bridge = createShinyBridge("chat");
    bridge.sendShowClaudeEditsInRStudio(false);
    const event = inputValues.find(
      (item) => item.id === "chat_show_claude_edits_in_rstudio",
    );
    expect(event).toBeTruthy();
    expect(event!.value).toMatchObject({ value: false });
  });
});
