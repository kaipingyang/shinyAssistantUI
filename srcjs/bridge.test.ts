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
    handlers["chat:sessions"]({ sessions: [{ id: "s1", title: "t", preview: "p", createdAt: "2026" }] });
    const received: unknown[] = [];
    b.onSessions((d) => received.push(d));
    expect(received).toHaveLength(1);
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

  it("sendCancel 发到 _cancel 子 input", () => {
    const b = createShinyBridge("chat");
    b.sendCancel("t1");
    expect(inputValues[0].id).toBe("chat_cancel");
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
