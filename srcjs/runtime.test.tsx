// @vitest-environment jsdom
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { renderHook, act, cleanup } from "@testing-library/react";
import { useShinyRuntime } from "./runtime";

// mock 全局 Shiny：捕获注册的 customMessageHandler + 记录 setInputValue
type Handler = (data: unknown) => void;
let handlers: Map<string, Handler>;
let inputs: Array<{ id: string; value: any }>;

beforeEach(() => {
  handlers = new Map();
  inputs = [];
  localStorage.clear();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (globalThis as any).Shiny = {
    addCustomMessageHandler: (t: string, h: Handler) => handlers.set(t, h),
    setInputValue: (id: string, value: unknown) => inputs.push({ id, value }),
  };
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

// 模拟 R 发送 customMessage（带 inputId 前缀 "test:"）
async function fireR(type: string, data: unknown) {
  await act(async () => {
    handlers.get(`test:${type}`)?.(data);
  });
}

function setup() {
  return renderHook(() => useShinyRuntime("test", {}));
}

// 当前线程消息
function messages(result: ReturnType<typeof setup>["result"]) {
  return result.current.runtime.thread.getState().messages;
}
function currentThreadId(result: ReturnType<typeof setup>["result"]) {
  return result.current.runtime.threads.getState().mainThreadId;
}

describe("useShinyRuntime — onNew 基本流", () => {
  it("发消息 → user 气泡 + 出站 setInputValue", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hello");
      await result.current.runtime.thread.composer.send();
    });
    const msgs = messages(result);
    const userMsg = msgs.find((m) => m.role === "user");
    expect(userMsg).toBeTruthy();
    // 出站消息发到 inputId "test"
    const sent = inputs.find((i) => i.id === "test");
    expect(sent).toBeTruthy();
    expect(sent!.value.text).toBe("hello");
  });

  it("chunk 累积到同一 assistant 消息", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hi");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("chunk", { text: "Hello ", threadId: tid });
    await fireR("chunk", { text: "world", threadId: tid });
    const msgs = messages(result);
    const assistant = msgs.find((m) => m.role === "assistant");
    expect(assistant).toBeTruthy();
    const text = (assistant!.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
    expect(text).toBe("Hello world");
  });

  it("done → isRunning false + localStorage 落盘", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hi");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("chunk", { text: "reply", threadId: tid });
    await fireR("done", { threadId: tid });
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    const saved = localStorage.getItem(`shinyAssistantUI:test:msgs:${tid}`);
    expect(saved).toBeTruthy();
    expect(saved).toContain("reply");
  });
});

describe("useShinyRuntime — onError / thinking", () => {
  it("error → 追加错误消息 + isRunning false", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hi");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("error", { message: "boom", threadId: tid });
    const msgs = messages(result);
    const err = msgs.find((m) => {
      const t = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return t.includes("boom");
    });
    expect(err).toBeTruthy();
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
  });

  it("thinking → reasoning part 累积", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hi");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("thinking", { text: "let me ", threadId: tid });
    await fireR("thinking", { text: "think", threadId: tid });
    const msgs = messages(result);
    const reasoning = msgs.flatMap((m) => (m.content as any[]) ?? []).find((p) => p.type === "reasoning");
    expect(reasoning?.text).toBe("let me think");
  });
});

describe("useShinyRuntime — tool 流式三段", () => {
  it("start → 空壳 tool-call；delta → argsText 累积；result → 填充", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("do it");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("tool-call-start", { toolCallId: "tc1", toolName: "bash", threadId: tid });
    let tc = messages(result).flatMap((m) => (m.content as any[]) ?? []).find((p) => p.type === "tool-call");
    expect(tc).toBeTruthy();
    expect(tc.toolName).toBe("bash");

    await fireR("tool-call-delta", { toolCallId: "tc1", delta: "{\"cmd", threadId: tid });
    await fireR("tool-call-delta", { toolCallId: "tc1", delta: "\":\"ls\"}", threadId: tid });
    tc = messages(result).flatMap((m) => (m.content as any[]) ?? []).find((p) => p.type === "tool-call");
    expect(tc.argsText).toBe("{\"cmd\":\"ls\"}");

    await fireR("tool-result", { toolCallId: "tc1", result: "file1\nfile2", threadId: tid });
    tc = messages(result).flatMap((m) => (m.content as any[]) ?? []).find((p) => p.type === "tool-call");
    expect(tc.result).toBe("file1\nfile2");
  });

  it("ellmer 路径：仅 tool-call（无 start）整包新建", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("do it");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("tool-call", { toolCallId: "tc2", toolName: "get_weather", args: { city: "BJ" }, argsText: "{\"city\":\"BJ\"}", threadId: tid });
    const tc = messages(result).flatMap((m) => (m.content as any[]) ?? []).find((p) => p.type === "tool-call");
    expect(tc.toolName).toBe("get_weather");
    expect(tc.argsText).toBe("{\"city\":\"BJ\"}");
  });
});

describe("useShinyRuntime — 多线程隔离", () => {
  it("不同 threadId 的 chunk 不串（切线程后旧 run 仍归旧线程）", async () => {
    const { result } = setup();
    // 线程 1 发消息
    await act(async () => {
      await result.current.runtime.thread.composer.setText("msg1");
      await result.current.runtime.thread.composer.send();
    });
    const t1 = currentThreadId(result);
    // 新建线程 2
    await act(async () => { result.current.switchToNewThread(); });
    const t2 = currentThreadId(result);
    expect(t2).not.toBe(t1);
    // 旧线程 t1 的 chunk 到达（后台 run）
    await fireR("chunk", { text: "late reply", threadId: t1 });
    // t1 的消息落到 t1，不污染当前 t2
    const currentMsgs = messages(result);
    const leaked = currentMsgs.some((m) => {
      const txt = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return txt.includes("late reply");
    });
    expect(leaked).toBe(false);
  });
});

describe("useShinyRuntime — 多 tab storage 守卫", () => {
  it("正在流式的线程不被跨 tab storage 覆盖", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("mine");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("chunk", { text: "streaming...", threadId: tid });
    // 此刻 tid 正在跑（activeRunsRef 有它）。模拟另一 tab 写盘该线程
    // 真写 localStorage（守卫失效时 loadMessages 会读到并覆盖，确保测试非假阳性）
    localStorage.setItem(`shinyAssistantUI:test:msgs:${tid}`, JSON.stringify([
      { id: "ghost", role: "user", content: [{ type: "text", text: "OVERWRITE" }] },
    ]));
    await act(async () => {
      window.dispatchEvent(new StorageEvent("storage", {
        key: `shinyAssistantUI:test:msgs:${tid}`,
        newValue: JSON.stringify([{ id: "ghost", role: "user", content: [{ type: "text", text: "OVERWRITE" }] }]),
      }));
    });
    // 流式中的消息未被磁盘覆盖
    const msgs = messages(result);
    const overwritten = msgs.some((m) => {
      const txt = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return txt.includes("OVERWRITE");
    });
    expect(overwritten).toBe(false);
    // 原流式内容仍在
    const stillThere = msgs.some((m) => {
      const txt = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return txt.includes("streaming...");
    });
    expect(stillThere).toBe(true);
  });

  it("非活动（非当前）线程的 storage 变化被同步", async () => {
    const { result } = setup();
    // 当前线程 t1
    await act(async () => {
      await result.current.runtime.thread.composer.setText("t1msg");
      await result.current.runtime.thread.composer.send();
    });
    const t1 = currentThreadId(result);
    await fireR("done", { threadId: t1 });
    // 切到新线程 t2（t1 变成非当前、非活动）
    await act(async () => { result.current.switchToNewThread(); });
    const t2 = currentThreadId(result);
    // 另一 tab 给 t1 写盘（t1 非当前、非 active → 应被同步进 map）
    // 注意：storage 监听里走 loadMessages 从 localStorage 读，故必须真写入 localStorage，
    // StorageEvent 仅作为触发信号（jsdom 不会因 dispatch 自动改 localStorage）。
    const ghostMsg = { id: "sync1", role: "user", content: [{ type: "text", text: "SYNCED" }] };
    localStorage.setItem(`shinyAssistantUI:test:msgs:${t1}`, JSON.stringify([ghostMsg]));
    await act(async () => {
      window.dispatchEvent(new StorageEvent("storage", {
        key: `shinyAssistantUI:test:msgs:${t1}`,
        newValue: JSON.stringify([ghostMsg]),
      }));
    });
    // 切回 t1，应看到同步的消息
    await act(async () => {
      result.current.runtime.threads.switchToThread(t1);
    });
    const msgs = messages(result);
    const synced = msgs.some((m) => {
      const txt = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return txt.includes("SYNCED");
    });
    expect(synced).toBe(true);
    expect(t2).not.toBe(t1);
  });
});

describe("useShinyRuntime — 跨线程 run 收尾隔离", () => {
  it("切线程后旧线程的 done 到达，不误清当前线程 running", async () => {
    const { result } = setup();
    // 线程 t1 发消息（run 中）
    await act(async () => {
      await result.current.runtime.thread.composer.setText("q1");
      await result.current.runtime.thread.composer.send();
    });
    const t1 = currentThreadId(result);
    await fireR("chunk", { text: "t1 reply", threadId: t1 });

    // 切到新线程 t2 并发消息（t2 也在 run）
    await act(async () => { result.current.switchToNewThread(); });
    const t2 = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("q2");
      await result.current.runtime.thread.composer.send();
    });
    expect(result.current.runtime.thread.getState().isRunning).toBe(true); // t2 在跑

    // 旧线程 t1 的 done 到达（后台 run 完成）——不应清当前 t2 的 running
    await fireR("done", { threadId: t1 });
    expect(result.current.runtime.thread.getState().isRunning).toBe(true); // t2 仍在跑

    // t2 自己的 done 才清 t2 running
    await fireR("done", { threadId: t2 });
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    expect(t2).not.toBe(t1);
  });

  it("切线程后旧线程 chunk 仍写入旧线程（切回可见）", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("q1");
      await result.current.runtime.thread.composer.send();
    });
    const t1 = currentThreadId(result);
    await act(async () => { result.current.switchToNewThread(); });
    // 旧线程 t1 后台继续流式
    await fireR("chunk", { text: "background reply", threadId: t1 });
    await fireR("done", { threadId: t1 });
    // 切回 t1，应看到后台完成的回复
    await act(async () => { result.current.runtime.threads.switchToThread(t1); });
    const msgs = messages(result);
    const seen = msgs.some((m) => {
      const txt = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return txt.includes("background reply");
    });
    expect(seen).toBe(true);
  });
});




