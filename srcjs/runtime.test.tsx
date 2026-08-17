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

function setup(config: Record<string, unknown> = {}) {
  return renderHook(() => useShinyRuntime("test", config));
}

function setupCopilot(status: "disabled" | "checking" | "starting" | "ready" | "failed" = "checking", autoStart = true) {
  return setup({
    addons: {
      copilotService: { version: 1, state: { status, autoStart } },
    },
  });
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

describe("useShinyRuntime — per-thread composer drafts", () => {
  it("preserves independent unsent text while switching between threads", async () => {
    const { result } = setup();
    const threadA = currentThreadId(result);

    await act(async () => {
      result.current.runtime.thread.composer.setText("draft A");
      result.current.switchToNewThread();
    });
    const threadB = currentThreadId(result);
    expect(threadB).not.toBe(threadA);
    expect(result.current.runtime.thread.composer.getState().text).toBe("");

    await act(async () => {
      result.current.runtime.thread.composer.setText("draft B");
      result.current.runtime.threads.switchToThread(threadA);
    });
    expect(result.current.runtime.thread.composer.getState().text).toBe("draft A");

    await act(async () => result.current.runtime.threads.switchToThread(threadB));
    expect(result.current.runtime.thread.composer.getState().text).toBe("draft B");
  });

  it("does not restore a submitted draft after switching away and back", async () => {
    const { result } = setup();
    const threadA = currentThreadId(result);

    await act(async () => {
      result.current.runtime.thread.composer.setText("send once");
      await result.current.runtime.thread.composer.send();
    });
    expect(result.current.runtime.thread.composer.getState().text).toBe("");

    await act(async () => result.current.switchToNewThread());
    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runtime.thread.composer.getState().text).toBe("");
  });

  it("clears drafts when the addin switches working directories", async () => {
    const { result } = setup({ working_dir: "/old-project" });
    const oldThread = currentThreadId(result);

    await act(async () => {
      result.current.runtime.thread.composer.setText("old project draft");
      result.current.switchToNewThread();
    });
    await fireR("working-dir", { dir: "/new-project", recent: [] });
    expect(result.current.runtime.thread.composer.getState().text).toBe("");

    await act(async () => result.current.runtime.threads.switchToThread(oldThread));
    expect(result.current.runtime.thread.composer.getState().text).toBe("");
  });

  it("does not resurrect a submitted local slash action", async () => {
    const { result } = setup({
      action_items: [{ id: "context", command: "context", label: "Context" }],
    });
    const threadA = currentThreadId(result);

    await act(async () => {
      result.current.runtime.thread.composer.setText("/context");
      await result.current.runtime.thread.composer.send();
      result.current.switchToNewThread();
    });
    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runtime.thread.composer.getState().text).toBe("");
    expect(inputs.some((item) => item.id === "test")).toBe(false);
  });

  it("preserves archived drafts and clears permanently deleted drafts", async () => {
    const { result } = setup({ persistence: "server" });
    const threadA = "draft-server-a";
    const threadB = "draft-server-b";
    const sessions = [
      { id: threadA, title: "Draft A" },
      { id: threadB, title: "Draft B" },
    ];
    await fireR("sessions", { sessions });

    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    await act(async () => {
      result.current.runtime.thread.composer.setText("archive me");
      result.current.runtime.threads.switchToThread(threadB);
    });
    await act(async () => result.current.runtime.threads.getItemById(threadA).archive());
    await act(async () => result.current.runtime.threads.getItemById(threadA).unarchive());
    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runtime.thread.composer.getState().text).toBe("archive me");

    await act(async () => result.current.runtime.threads.switchToThread(threadB));
    await act(async () => result.current.runtime.threads.getItemById(threadA).delete());
    await fireR("sessions", { sessions });
    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runtime.thread.composer.getState().text).toBe("");
  });
});



describe("useShinyRuntime — optional copilot addin", () => {
  it("registers no copilot channels and applies no readiness barrier without the addon", async () => {
    const { result } = setup();
    expect(handlers.has("test:copilot-service-status")).toBe(false);
    expect(inputs.some((item) => item.id === "test_copilot_service_ready")).toBe(false);

    await act(async () => {
      await result.current.runtime.thread.composer.setText("generic submit");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["generic submit"]);
  });
});
describe("useShinyRuntime — copilot-api readiness barrier", () => {
  it("exposes authoritative service state updates from the backend", async () => {
    const { result } = setupCopilot();

    await fireR("copilot-service-status", {
      status: "checking",
      autoStart: true,
      message: "Checking copilot-api",
    });
    expect(result.current.serviceState).toMatchObject({
      status: "checking",
      autoStart: true,
      message: "Checking copilot-api",
    });

    await fireR("copilot-service-status", {
      status: "failed",
      autoStart: true,
      message: "copilot-api did not become ready",
    });
    expect(result.current.serviceState).toMatchObject({
      status: "failed",
      message: "copilot-api did not become ready",
    });
  });

  it("holds an explicit pre-ready submission and dispatches it exactly once when ready", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "checking", autoStart: true });

    await act(async () => {
      await result.current.runtime.thread.composer.setText("wait for copilot");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = () => inputs.filter((item) => item.id === "test");
    expect(outbound()).toHaveLength(0);

    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(outbound()).toHaveLength(1);
    expect(outbound()[0].value.text).toBe("wait for copilot");

    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(outbound()).toHaveLength(1);
  });

  it("releases multiple explicit submissions FIFO, one terminal result at a time", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "starting", autoStart: true });

    for (const text of ["first", "second"]) {
      await act(async () => {
        await result.current.runtime.thread.composer.setText(text);
        await result.current.runtime.thread.composer.send();
      });
    }
    const outbound = () => inputs.filter((item) => item.id === "test");
    expect(outbound()).toHaveLength(0);
    expect(result.current.pendingServiceSubmissions).toBe(2);

    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(outbound().map((item) => item.value.text)).toEqual(["first"]);
    const tid = currentThreadId(result);
    await fireR("done", { threadId: tid });
    expect(outbound().map((item) => item.value.text)).toEqual(["first", "second"]);
    await fireR("done", { threadId: tid });
    expect(outbound()).toHaveLength(2);
  });

  it("ignores a stale same-thread terminal and only advances the matching run", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "starting", autoStart: true });
    for (const text of ["first", "second"]) {
      await act(async () => {
        await result.current.runtime.thread.composer.setText(text);
        await result.current.runtime.thread.composer.send();
      });
    }
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    const outbound = () => inputs.filter((item) => item.id === "test");
    const tid = currentThreadId(result);
    const firstRunId = outbound()[0].value.runId as string;

    await fireR("done", { threadId: tid, runId: "older-run" });
    expect(outbound().map((item) => item.value.text)).toEqual(["first"]);

    await fireR("done", { threadId: tid, runId: firstRunId });
    expect(outbound().map((item) => item.value.text)).toEqual(["first", "second"]);
  });

  it("serializes the service FIFO before a clock-queued message", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "starting", autoStart: true });
    for (const text of ["service A", "service B"]) {
      await act(async () => {
        await result.current.runtime.thread.composer.setText(text);
        await result.current.runtime.thread.composer.send();
      });
    }
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    const outbound = () => inputs.filter((item) => item.id === "test");
    const tid = currentThreadId(result);
    await act(async () => result.current.enqueueMessage("clock C"));

    await fireR("done", { threadId: tid, runId: outbound()[0].value.runId });
    expect(outbound().map((item) => item.value.text)).toEqual(["service A", "service B"]);
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toEqual(["service A", "service B"]);

    await fireR("done", { threadId: tid, runId: outbound()[1].value.runId });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toEqual([
      "service A", "service B", "clock C",
    ]);
  });

  it("serializes Enter submissions made while the same thread is running", async () => {
    const { result } = setupCopilot("ready");
    for (const text of ["running first", "enter second"]) {
      await act(async () => {
        await result.current.runtime.thread.composer.setText(text);
        await result.current.runtime.thread.composer.send();
      });
    }
    const outbound = () => inputs.filter((item) => item.id === "test");
    expect(outbound().map((item) => item.value.text)).toEqual(["running first"]);
    expect(result.current.pendingServiceSubmissions).toBe(1);
    const tid = currentThreadId(result);
    await fireR("done", { threadId: tid, runId: outbound()[0].value.runId });
    expect(outbound().map((item) => item.value.text)).toEqual([
      "running first", "enter second",
    ]);
  });

  it("does not let another thread service run starve this thread clock queue", async () => {
    const { result } = setupCopilot();
    const threadA = currentThreadId(result);
    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("service A");
      await result.current.runtime.thread.composer.send();
    });
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    const outbound = () => inputs.filter((item) => item.id === "test");

    await act(async () => result.current.switchToNewThread());
    const threadB = currentThreadId(result);
    expect(threadB).not.toBe(threadA);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("ordinary B");
      await result.current.runtime.thread.composer.send();
      result.current.enqueueMessage("clock B");
    });
    const ordinaryB = outbound().find((item) => item.value.text === "ordinary B")!;
    await fireR("done", { threadId: threadB, runId: ordinaryB.value.runId });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toContain("clock B");
  });

  it("derives running UI from the current thread while a background service run proceeds", async () => {
    const { result } = setupCopilot();
    const threadA = currentThreadId(result);
    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("background A");
      await result.current.runtime.thread.composer.send();
      result.current.switchToNewThread();
    });
    const threadB = currentThreadId(result);
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runtime.thread.getState().isRunning).toBe(true);
    await act(async () => result.current.runtime.threads.switchToThread(threadB));
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
  });

  it("requeues a clock dispatch if another run starts during its delay window", async () => {
    const { result } = setupCopilot("ready");
    await act(async () => {
      await result.current.runtime.thread.composer.setText("first run");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = () => inputs.filter((item) => item.id === "test");
    const tid = currentThreadId(result);
    await act(async () => result.current.enqueueMessage("clock delayed"));
    await fireR("done", { threadId: tid, runId: outbound()[0].value.runId });

    await act(async () => {
      await result.current.runtime.thread.composer.setText("wins window");
      await result.current.runtime.thread.composer.send();
    });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toEqual(["first run", "wins window"]);

    await fireR("done", { threadId: tid, runId: outbound()[1].value.runId });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toEqual([
      "first run", "wins window", "clock delayed",
    ]);
  });

  it("waits for an existing ordinary run before draining a ready service submission", async () => {
    const { result } = setupCopilot("ready");
    await act(async () => {
      await result.current.runtime.thread.composer.setText("ordinary run");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = () => inputs.filter((item) => item.id === "test");
    const tid = currentThreadId(result);
    const ordinaryRunId = outbound()[0].value.runId;

    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("service queued");
      await result.current.runtime.thread.composer.send();
    });
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(outbound().map((item) => item.value.text)).toEqual(["ordinary run"]);

    await fireR("done", { threadId: tid, runId: ordinaryRunId });
    expect(outbound().map((item) => item.value.text)).toEqual([
      "ordinary run", "service queued",
    ]);
  });

  it("does not let reload bypass pending service work", async () => {
    const { result } = setupCopilot("ready");
    await act(async () => {
      await result.current.runtime.thread.composer.setText("original");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    const originalRun = inputs.find((item) => item.id === "test")!.value.runId;
    await fireR("chunk", { text: "answer", threadId: tid });
    await fireR("done", { threadId: tid, runId: originalRun });
    const assistant = messages(result).find((message) => message.role === "assistant")!;

    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("queued");
      await result.current.runtime.thread.composer.send();
      result.current.runtime.thread.getMessageById(assistant.id).reload();
    });
    expect(inputs.filter((item) => item.id === "test" && item.value.type === "reload"))
      .toHaveLength(0);
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["original", "queued"]);
  });

  it("drops clock-queued text when the working directory changes", async () => {
    const { result } = setupCopilot("ready");
    await act(async () => {
      await result.current.runtime.thread.composer.setText("old cwd running");
      await result.current.runtime.thread.composer.send();
      result.current.enqueueMessage("old cwd clock");
    });
    const outbound = () => inputs.filter((item) => item.id === "test");
    const tid = currentThreadId(result);
    await fireR("working-dir", { dir: "/new-cwd", recent: [] });
    await fireR("done", { threadId: tid, runId: outbound()[0].value.runId });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });
    expect(outbound().map((item) => item.value.text)).toEqual(["old cwd running"]);
  });

  it("cancels waiting submissions on cwd change or when auto-start is disabled", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "failed", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("old project");
      await result.current.runtime.thread.composer.send();
    });
    expect(result.current.pendingServiceSubmissions).toBe(1);
    await fireR("working-dir", { dir: "/new-project", recent: [] });
    expect(result.current.pendingServiceSubmissions).toBe(0);
    expect(messages(result).filter((message) => message.role === "user")).toHaveLength(0);
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);
    expect(inputs.some((item) => item.id === "test_cancel_reserved_submissions")).toBe(true);

    await fireR("copilot-service-status", { status: "failed", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("disabled wait");
      await result.current.runtime.thread.composer.send();
    });
    await act(async () => {
      result.current.setAutoStartCopilotApi?.(false);
    });
    expect(result.current.pendingServiceSubmissions).toBe(0);
    expect(result.current.serviceState?.status).toBe("disabled");
    expect(messages(result).filter((message) => message.role === "user")).toHaveLength(0);

    await act(async () => {
      await result.current.runtime.thread.composer.setText("after disable");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["after disable"]);
    await fireR("copilot-service-status", { status: "disabled", autoStart: false });
    expect(result.current.pendingServiceSubmissions).toBe(0);
  });

  it("enters checking immediately when auto-start is re-enabled", async () => {
    const { result } = setupCopilot("disabled", false);
    await fireR("copilot-service-status", { status: "disabled", autoStart: false });
    await act(async () => result.current.setAutoStartCopilotApi?.(true));
    expect(result.current.serviceState?.status).toBe("checking");

    await act(async () => {
      await result.current.runtime.thread.composer.setText("wait after enable");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);
    expect(result.current.pendingServiceSubmissions).toBe(1);
    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["wait after enable"]);
  });

  it("retains waiting submissions through failure and never auto-sends an ordinary draft", async () => {
    const { result } = setupCopilot();
    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("draft only");
    });
    expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);

    await act(async () => {
      await result.current.runtime.thread.composer.send();
    });
    await fireR("copilot-service-status", { status: "failed", autoStart: true });
    expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);
    expect(result.current.pendingServiceSubmissions).toBe(1);

    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["draft only"]);
  });

  it("replaces the current thread server-command snapshot, including an empty clear", async () => {
    const { result } = setupCopilot();
    const tid = currentThreadId(result);
    await fireR("server-commands", {
      threadId: tid,
      commands: [{ name: "old" }, { name: "removed" }],
    });
    expect(result.current.serverCommands.map((command) => command.name)).toEqual(["old", "removed"]);

    await fireR("server-commands", { threadId: tid, commands: [] });
    expect(result.current.serverCommands).toEqual([]);

    await fireR("server-commands", { threadId: tid, commands: [{ name: "new" }] });
    expect(result.current.serverCommands.map((command) => command.name)).toEqual(["new"]);
  });
});

describe("useShinyRuntime — onError / thinking", () => {
  it("keeps every non-terminal background task active across turn completion until its own terminal event", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("go");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("task", {
      taskId: "t-1", kind: "started", description: "Inspect repository",
      toolName: "Read", status: "running", threadId: tid,
    });
    await fireR("task", {
      taskId: "t-2", kind: "started", description: "Run tests",
      toolName: "Bash", status: "running", threadId: tid,
    });
    expect(result.current.tasks.map((task) => task.taskId)).toEqual(["t-1", "t-2"]);

    await fireR("done", { threadId: tid });
    expect(result.current.tasks.map((task) => task.taskId)).toEqual(["t-1", "t-2"]);

    await fireR("task", {
      taskId: "t-1", kind: "updated", status: "completed", threadId: tid,
    });
    expect(result.current.tasks.map((task) => task.taskId)).toEqual(["t-2"]);

    await fireR("task", {
      taskId: "t-2", kind: "updated", status: "killed", threadId: tid,
    });
    expect(result.current.tasks).toEqual([]);
  });

  it("exposes only the current run's latest terminal activity and rejects an old run during a new turn", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("first turn");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    const firstRunId = inputs.filter((item) => item.id === "test").at(-1)?.value.runId;
    expect(firstRunId).toBeTruthy();

    await fireR("task", {
      taskId: "t-1", kind: "notification", description: "Read files",
      status: "completed", threadId: tid, runId: firstRunId,
    });
    expect(result.current.recentTasks.map((task) => task.taskId)).toEqual(["t-1"]);

    await fireR("task", {
      taskId: "t-2", kind: "notification", description: "Run tests",
      status: "failed", threadId: tid, runId: firstRunId,
    });
    expect(result.current.recentTasks.map((task) => task.taskId)).toEqual(["t-2"]);

    await fireR("done", { threadId: tid, runId: firstRunId });
    expect(result.current.recentTasks).toEqual([]);

    await act(async () => {
      await result.current.runtime.thread.composer.setText("second turn");
      await result.current.runtime.thread.composer.send();
    });
    const secondRunId = inputs.filter((item) => item.id === "test").at(-1)?.value.runId;
    expect(secondRunId).toBeTruthy();
    expect(secondRunId).not.toBe(firstRunId);

    await fireR("task", {
      taskId: "late-old-run", kind: "notification", description: "Late event",
      status: "completed", threadId: tid, runId: firstRunId,
    });
    expect(result.current.runtime.thread.getState().isRunning).toBe(true);
    expect(result.current.recentTasks).toEqual([]);

    await fireR("task", {
      taskId: "current-run", kind: "notification", description: "Current event",
      status: "completed", threadId: tid, runId: secondRunId,
    });
    expect(result.current.recentTasks.map((task) => task.taskId)).toEqual(["current-run"]);
  });

  it("error → 追加错误消息、清除当前latest activity并结束running", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("hi");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    const runId = inputs.filter((item) => item.id === "test").at(-1)?.value.runId;
    expect(runId).toBeTruthy();
    await fireR("task", {
      taskId: "before-error", kind: "notification", description: "Before error",
      status: "completed", threadId: tid, runId,
    });
    expect(result.current.recentTasks.map((task) => task.taskId)).toEqual(["before-error"]);

    await fireR("error", { message: "boom", threadId: tid, runId });
    const msgs = messages(result);
    const err = msgs.find((m) => {
      const t = (m.content as any[]).filter((p) => p.type === "text").map((p) => p.text).join("");
      return t.includes("boom");
    });
    expect(err).toBeTruthy();
    expect(result.current.recentTasks).toEqual([]);
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

  it("projects growing Write Markdown args before the final canonical tool-call", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("write it");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("tool-call-start", {
      toolCallId: "write-stream",
      toolName: "Write",
      annotations: { parentToolCallId: null },
      threadId: tid,
    });

    await fireR("tool-call-delta", {
      toolCallId: "write-stream",
      delta: '{"file_path":"report.md","content":"# Liv',
      threadId: tid,
    });
    await fireR("tool-call-delta", {
      toolCallId: "write-stream",
      delta: 'e\\n\\n- first',
      threadId: tid,
    });

    let tc = messages(result)
      .flatMap((m) => (m.content as any[]) ?? [])
      .find((p) => p.type === "tool-call" && p.toolCallId === "write-stream");
    expect(tc.argsText).toBe('{"file_path":"report.md","content":"# Live\\n\\n- first');
    expect(tc.args).toEqual({
      file_path: "report.md",
      content: "# Live\n\n- first",
    });
    expect(tc.artifact.argsStreaming).toBe(true);

    await fireR("tool-call", {
      toolCallId: "write-stream",
      toolName: "Write",
      args: { file_path: "report.md", content: "# Live\n\n- first\n- final" },
      argsText: '{"file_path":"report.md","content":"# Live\\n\\n- first\\n- final"}',
      annotations: { defaultOpen: true, argsStreaming: true },
      threadId: tid,
    });

    tc = messages(result)
      .flatMap((m) => (m.content as any[]) ?? [])
      .find((p) => p.type === "tool-call" && p.toolCallId === "write-stream");
    expect(tc.args.content).toBe("# Live\n\n- first\n- final");
    expect(tc.artifact).toMatchObject({
      parentToolCallId: null,
      defaultOpen: true,
      argsStreaming: false,
    });
  });

  it("clears provisional streaming state when a result arrives without a canonical tool-call", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("write it");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("tool-call-start", { toolCallId: "write-result", toolName: "Write", threadId: tid });
    await fireR("tool-call-delta", {
      toolCallId: "write-result",
      delta: '{"file_path":"x.md","content":"partial',
      threadId: tid,
    });
    await fireR("tool-result", {
      toolCallId: "write-result",
      result: "done",
      isError: false,
      threadId: tid,
    });
    const tc = messages(result)
      .flatMap((m) => (m.content as any[]) ?? [])
      .find((p) => p.type === "tool-call" && p.toolCallId === "write-result");
    expect(tc.result).toBe("done");
    expect(tc.artifact.argsStreaming).toBe(false);
  });

  it("settles a partial Write card when the run errors", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("write it");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("tool-call-start", { toolCallId: "write-error", toolName: "Write", threadId: tid });
    await fireR("tool-call-delta", {
      toolCallId: "write-error",
      delta: '{"file_path":"x.md","content":"partial',
      threadId: tid,
    });
    await fireR("error", { message: "backend failed", threadId: tid });
    const tc = messages(result)
      .flatMap((m) => (m.content as any[]) ?? [])
      .find((p) => p.type === "tool-call" && p.toolCallId === "write-error");
    expect(tc.result).toBe("Interrupted");
    expect(tc.isError).toBe(true);
    expect(tc.artifact.argsStreaming).toBe(false);
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

  it("keeps each thread streaming message id isolated across interleaved terminals", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("A");
      await result.current.runtime.thread.composer.send();
    });
    const threadA = currentThreadId(result);
    const runA = inputs.find((item) => item.id === "test" && item.value.text === "A")!.value.runId;
    await act(async () => result.current.switchToNewThread());
    const threadB = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("B");
      await result.current.runtime.thread.composer.send();
    });

    await fireR("chunk", { text: "A1", threadId: threadA });
    await fireR("chunk", { text: "B1", threadId: threadB });
    await fireR("done", { threadId: threadA, runId: runA });
    await fireR("chunk", { text: "B2", threadId: threadB });

    const assistantTexts = messages(result)
      .filter((message) => message.role === "assistant")
      .map((message) => (message.content as any[])
        .filter((part) => part.type === "text")
        .map((part) => part.text)
        .join(""));
    expect(assistantTexts).toEqual(["B1B2"]);
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






describe("useShinyRuntime — permission mode capability", () => {
  const permissionConfig = {
    ui_capabilities: {
      permission_mode: {
        value: "plan",
        options: [
          { value: "default", label: "Manual" },
          { value: "plan", label: "Plan" },
          { value: "acceptEdits", label: "Auto-edit" },
          { value: "bypassPermissions", label: "Bypass" },
        ],
      },
    },
  };

  it("capability absent keeps permission UI disabled", () => {
    const { result } = setup();
    expect(result.current.permissionMode).toBeUndefined();
  });

  it("exposes the capability initial mode and options", () => {
    const { result } = setup(permissionConfig);
    expect(result.current.permissionMode?.value).toBe("plan");
    expect(result.current.permissionMode?.options.map((x) => x.value)).toEqual([
      "default", "plan", "acceptEdits", "bypassPermissions",
    ]);
  });

  it("submits a silent action without chat bubbles and accepts matching canonical value", async () => {
    const { result } = setup(permissionConfig);
    const before = messages(result).length;
    await act(async () => { result.current.permissionMode?.setValue("acceptEdits"); });

    expect(messages(result)).toHaveLength(before);
    const sent = inputs.find((x) => x.id === "test_action")!;
    expect(sent.value).toMatchObject({
      id: "permissions:acceptEdits", silent: true,
    });
    expect(sent.value.requestId).toBeTruthy();
    expect(result.current.permissionMode).toMatchObject({ value: "acceptEdits", pending: true });

    await fireR("action-result", {
      threadId: sent.value.threadId, requestId: sent.value.requestId,
      actionId: sent.value.id, status: "ok", value: "acceptEdits",
    });
    expect(result.current.permissionMode).toMatchObject({
      value: "acceptEdits", pending: false, error: null,
    });
  });

  it("submits bypassPermissions as a silent permission action", async () => {
    const { result } = setup(permissionConfig);
    await act(async () => {
      result.current.permissionMode?.setValue("bypassPermissions");
    });
    const sent = inputs.find((item) => item.id === "test_action");
    expect(sent?.value).toMatchObject({
      id: "permissions:bypassPermissions",
      silent: true,
    });
    expect(messages(result)).toHaveLength(0);
  });

  it("reverts to the previous value on error and ignores stale results", async () => {
    const { result } = setup(permissionConfig);
    await act(async () => { result.current.permissionMode?.setValue("acceptEdits"); });
    const first = inputs.find((x) => x.id === "test_action")!.value;
    await act(async () => { result.current.permissionMode?.setValue("default"); });
    const second = inputs.filter((x) => x.id === "test_action")[1].value;

    await fireR("action-result", {
      threadId: first.threadId, requestId: first.requestId,
      actionId: first.id, status: "ok", value: "acceptEdits",
    });
    expect(result.current.permissionMode).toMatchObject({ value: "default", pending: true });

    await fireR("action-result", {
      threadId: second.threadId, requestId: second.requestId,
      actionId: second.id, status: "error", message: "rejected",
    });
    expect(result.current.permissionMode).toMatchObject({
      value: "plan", pending: false, error: "rejected",
    });
  });

  it("isolates canonical and pending modes by thread", async () => {
    const { result } = setup(permissionConfig);
    const firstThread = currentThreadId(result);
    await act(async () => { result.current.permissionMode?.setValue("acceptEdits"); });
    const request = inputs.find((x) => x.id === "test_action")!.value;

    await act(async () => { result.current.switchToNewThread(); });
    expect(currentThreadId(result)).not.toBe(firstThread);
    expect(result.current.permissionMode).toMatchObject({ value: "plan", pending: false });

    await fireR("action-result", {
      threadId: firstThread, requestId: request.requestId,
      actionId: request.id, status: "ok", value: "acceptEdits",
    });
    expect(result.current.permissionMode?.value).toBe("plan");

    await act(async () => { result.current.runtime.threads.switchToThread(firstThread); });
    expect(result.current.permissionMode).toMatchObject({ value: "acceptEdits", pending: false });
  });
});


describe("useShinyRuntime — ordinary action correlation", () => {
  it("keeps user/ack bubbles and updates concurrent actions by requestId", async () => {
    const { result } = setup();
    await act(async () => {
      result.current.invokeAction({ id: "first", label: "First action" });
      result.current.invokeAction({ id: "second", label: "Second action" });
    });
    expect(messages(result)).toHaveLength(4);
    const requests = inputs.filter((item) => item.id === "test_action").map((item) => item.value);
    expect(requests).toHaveLength(2);
    expect(requests[0].requestId).not.toBe(requests[1].requestId);

    await fireR("action-result", {
      threadId: requests[1].threadId,
      requestId: requests[1].requestId,
      actionId: "second",
      status: "ok",
      message: "Second completed",
    });
    const actionText = messages(result).map((message) =>
      (message.content as any[]).map((part) => part.text ?? "").join(""),
    );
    expect(actionText.some((text) => text.includes("Second completed"))).toBe(true);
    expect(actionText.some((text) => text.includes("First action"))).toBe(true);
  });

  it("keeps multiline action Markdown block structure", async () => {
    const { result } = setup();
    await act(async () => {
      result.current.invokeAction({ id: "context", label: "Context usage" });
    });
    const request = inputs.find((item) => item.id === "test_action")!.value;
    await fireR("action-result", {
      threadId: request.threadId,
      requestId: request.requestId,
      actionId: "context",
      status: "ok",
      message: "# Context Usage\n\n| Category | Tokens |\n| --- | --- |",
    });
    const ack = messages(result).find((message) => message.id.startsWith("ack-"))!;
    const text = (ack.content as any[]).map((part) => part.text ?? "").join("");
    expect(text).toBe("✓\n\n# Context Usage\n\n| Category | Tokens |\n| --- | --- |");
  });
});


describe("useShinyRuntime — permission progress correlation", () => {

  it.each([
    ["ok", "Conversation compacted", "complete"],
    ["error", "Compact timed out", "error"],
  ] as const)("settles compact progress with %s without starting an AI run", async (status, message, phase) => {
    const { result } = setup();
    await act(async () => {
      result.current.invokeAction({ id: "compact", label: "Compact conversation" });
    });
    const request = inputs.find((item) => item.id === "test_action")!.value;
    let ack = messages(result).find((item) => item.id.startsWith("ack-"))!;
    expect((ack.content as any[])[0]).toMatchObject({
      type: "data",
      name: "action-progress",
      data: { kind: "compact", phase: "starting" },
    });
    expect(result.current.blockingAction).toMatchObject({ kind: "compact" });

    await fireR("action-result", {
      threadId: request.threadId,
      requestId: request.requestId,
      actionId: "compact",
      status: "progress",
      message: "Compacting conversation…",
      value: {
        kind: "compact", phase: "compacting", startedAt: Date.now(),
        message: "Compacting conversation…",
      },
    });
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    ack = messages(result).find((item) => item.id.startsWith("ack-"))!;
    expect((ack.content as any[])[0]).toMatchObject({
      type: "data", name: "action-progress",
      data: { kind: "compact", phase: "compacting" },
    });
    expect(result.current.blockingAction).toMatchObject({ kind: "compact" });

    await fireR("action-result", {
      threadId: request.threadId,
      requestId: request.requestId,
      actionId: "compact",
      status,
      message,
      value: { kind: "compact", phase, startedAt: Date.now(), message },
    });
    ack = messages(result).find((item) => item.id.startsWith("ack-"))!;
    expect((ack.content as any[])[0]).toMatchObject({
      type: "data", name: "action-progress", data: { kind: "compact", phase },
    });
    expect(result.current.blockingAction).toBeUndefined();
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
  });

  it("client watchdog settles compact and releases blocking when terminal is lost", async () => {
    vi.useFakeTimers();
    try {
      const { result } = setup();
      await act(async () => {
        result.current.invokeAction({ id: "compact", label: "Compact conversation" });
      });
      expect(result.current.blockingAction).toMatchObject({ kind: "compact" });

      await act(async () => {
        vi.advanceTimersByTime(186_000);
      });

      const ack = messages(result).find((item) => item.id.startsWith("ack-"))!;
      expect((ack.content as any[])[0]).toMatchObject({
        type: "data",
        name: "action-progress",
        data: { kind: "compact", phase: "error" },
      });
      expect(result.current.blockingAction).toBeUndefined();
      expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  const config = {
    ui_capabilities: {
      permission_mode: {
        value: "default",
        options: [
          { value: "default", label: "Manual" },
          { value: "plan", label: "Plan" },
        ],
      },
    },
  };

  it.each([
    ["ok", "plan", null],
    ["error", undefined, "denied"],
  ] as const)("keeps request correlation across progress then %s", async (status, value, error) => {
    const { result } = setup(config);
    await act(async () => { result.current.permissionMode?.setValue("plan"); });
    const request = inputs.find((item) => item.id === "test_action")!.value;
    await fireR("action-result", {
      threadId: request.threadId, requestId: request.requestId,
      actionId: request.id, status: "progress", message: "Submitting",
    });
    expect(result.current.permissionMode).toMatchObject({ value: "plan", pending: true });

    await fireR("action-result", {
      threadId: request.threadId, requestId: request.requestId,
      actionId: request.id, status, value, message: error ?? "submitted",
    });
    expect(result.current.permissionMode?.pending).toBe(false);
    if (status === "ok") {
      expect(result.current.permissionMode).toMatchObject({ value: "plan", error: null });
    } else {
      expect(result.current.permissionMode).toMatchObject({ value: "default", error: "denied" });
    }
  });
});


describe("useShinyRuntime — direct slash actions", () => {
  const config = {
    action_items: [
      { id: "compact", command: "compact", label: "Compact conversation", section: "Context" },
      { id: "context", command: "context", label: "Context usage", section: "Context" },
    ],
  };

  it.each(["compact", "context"])("direct /%s invokes an action and never starts an AI run", async (name) => {
    const { result } = setup(config);
    await act(async () => {
      await result.current.runtime.thread.composer.setText(`/${name}`);
      await result.current.runtime.thread.composer.send();
    });

    expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);
    const action = inputs.find((item) => item.id === "test_action")?.value;
    expect(action).toMatchObject({ id: name });
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);
    const text = messages(result).map((message) =>
      (message.content as any[]).map((part) => part.text ?? "").join(""),
    );
    expect(text).toContain(`/${name}`);
  });

  it("unknown slash text remains a normal AI message", async () => {
    const { result } = setup(config);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("/unknown arg");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.find((item) => item.id === "test")?.value.text).toBe("/unknown arg");
    expect(inputs.filter((item) => item.id === "test_action")).toHaveLength(0);
  });

  it("a skill invocation remains literal for Claude Code to resolve", async () => {
    const { result } = setup({
      ...config,
      commands: [{ name: "github", description: "GitHub skill", prompt: "/github", category: "Personal Skills" }],
    });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("/github issue 42");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.find((item) => item.id === "test")?.value.text).toBe("/github issue 42");
  });
});


describe("useShinyRuntime — clear action effect", () => {
  const config = {
    action_items: [
      { id: "clear", command: "clear", label: "New conversation", section: "Context" },
    ],
  };

  it("switches to an empty new thread only after a successful backend result", async () => {
    const { result } = setup(config);
    const oldThread = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("/clear");
      await result.current.runtime.thread.composer.send();
    });
    const request = inputs.find((item) => item.id === "test_action")!.value;
    expect(currentThreadId(result)).toBe(oldThread);

    await fireR("action-result", {
      threadId: oldThread,
      requestId: request.requestId,
      actionId: "clear",
      status: "ok",
      message: "Starting new conversation",
      value: { effect: "new-thread" },
    });

    expect(currentThreadId(result)).not.toBe(oldThread);
    expect(messages(result)).toHaveLength(0);
  });

  it("keeps the current thread when clear fails", async () => {
    const { result } = setup(config);
    const oldThread = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("/clear");
      await result.current.runtime.thread.composer.send();
    });
    const request = inputs.find((item) => item.id === "test_action")!.value;
    await fireR("action-result", {
      threadId: oldThread,
      requestId: request.requestId,
      actionId: "clear",
      status: "error",
      message: "Clear failed",
      value: { effect: "new-thread" },
    });
    expect(currentThreadId(result)).toBe(oldThread);
  });
});


describe("useShinyRuntime — live IDE context capability", () => {
  const config = {
    ui_capabilities: {
      contract_version: 1,
      ide_context: { submit: true, preview: true, selection_visibility: true },
      workspace_mentions: { search: true, kinds: ["file", "folder"], line_ranges: true, literal: true },
    },
  };

  it("refreshes metadata and sends visibility without browser-side selection text", async () => {
    const { result } = setup(config);
    const refresh = inputs.find((x) => x.id === "test_ide_context_refresh")!;
    expect(refresh.value.threadId).toBe(currentThreadId(result));
    await fireR("ide-context", {
      requestId: refresh.value.requestId, threadId: refresh.value.threadId,
      relativePath: "R/app.R", startLine: 4, endLine: 6, hasSelection: true,
    });
    expect(result.current.ideContext).toMatchObject({ relativePath: "R/app.R", startLine: 4, endLine: 6 });

    await act(async () => { result.current.setSelectionVisible(false); });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("explain");
      await result.current.runtime.thread.composer.send();
    });
    const sent = inputs.find((x) => x.id === "test")!.value;
    expect(sent.ideContext).toEqual({ selectionVisible: false });
    expect(JSON.stringify(sent)).not.toContain("selectionText");
  });

  it("drops stale workspace results and accepts the latest correlated query", async () => {
    const { result } = setup(config);
    await act(async () => { result.current.searchWorkspace("old"); await new Promise((r) => setTimeout(r, 160)); });
    const first = inputs.filter((x) => x.id === "test_workspace_search").at(-1)!.value;
    await act(async () => { result.current.searchWorkspace("app"); await new Promise((r) => setTimeout(r, 160)); });
    const second = inputs.filter((x) => x.id === "test_workspace_search").at(-1)!.value;

    await fireR("workspace-results", {
      requestId: first.requestId, threadId: first.threadId,
      items: [{ kind: "file", path: "old.txt", insertText: "@old.txt" }],
    });
    expect(result.current.workspaceMentions.items).toEqual([]);
    await fireR("workspace-results", {
      requestId: second.requestId, threadId: second.threadId,
      items: [{ kind: "file", path: "R/app.R", insertText: "@R/app.R" }],
    });
    expect(result.current.workspaceMentions.items[0].path).toBe("R/app.R");
  });

  it("debounces rapid workspace queries into a single backend call", async () => {
    const { result } = setup(config);
    const before = inputs.filter((x) => x.id === "test_workspace_search").length;
    await act(async () => {
      result.current.searchWorkspace("a");
      result.current.searchWorkspace("ap");
      result.current.searchWorkspace("app");
      await new Promise((r) => setTimeout(r, 160));
    });
    const sent = inputs.filter((x) => x.id === "test_workspace_search");
    expect(sent.length - before).toBe(1);                 // 三次连打 → 只发一次
    expect(sent.at(-1)!.value.query).toBe("app");
  });

  it("reload never sends an IDE context policy", async () => {
    const { result } = setup(config);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("first");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await fireR("chunk", { text: "answer", threadId: tid });
    await fireR("done", { threadId: tid });
    const assistant = messages(result).find((message) => message.role === "assistant")!;
    expect(assistant).toBeDefined();
    await act(async () => {
      result.current.runtime.thread.getMessageById(assistant.id).reload();
    });
    const reload = inputs.find((item) => item.id === "test" && item.value.type === "reload");
    expect(reload).toBeDefined();
    expect(reload!.value.ideContext).toBeUndefined();
  });
});


describe("useShinyRuntime — historical session lazy load state", () => {
  it("loads only after click, deduplicates while loading, and marks loaded on :load-thread", async () => {
    const { result } = setup();
    const initialThread = currentThreadId(result);
    const historicalThread = "session-history-1";

    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "History", createdAt: "2026-07-01T00:00:00Z" }],
    });
    const loadRequests = () => inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    );
    expect(loadRequests()).toHaveLength(0);

    await act(async () => {
      result.current.runtime.threads.switchToThread(historicalThread);
      result.current.runtime.threads.switchToThread(historicalThread);
    });
    expect(loadRequests()).toHaveLength(1);
    expect(loadRequests()[0].value).toMatchObject({
      sessionId: historicalThread,
      threadId: historicalThread,
    });

    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "old-user", role: "user", content: [{ type: "text", text: "restored" }] }],
    });
    expect(messages(result).some((message) => message.id === "old-user")).toBe(true);
    await act(async () => {
      result.current.runtime.threads.switchToThread(initialThread);
    });
    await act(async () => {
      result.current.runtime.threads.switchToThread(historicalThread);
    });
    expect(loadRequests()).toHaveLength(2);
    expect(result.current.readingHistory).toBe(true);
    // Keep the previous snapshot visible while its authoritative refresh loads.
    expect(messages(result).some((message) => message.id === "old-user")).toBe(true);

    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [
        { id: "old-user", role: "user", content: [{ type: "text", text: "restored" }] },
        {
          id: "late-read", role: "assistant", status: { type: "complete", reason: "stop" },
          content: [{
            type: "tool-call", toolCallId: "read-late", toolName: "Read",
            args: { file_path: "functions/process_sdtm_data.R" },
            argsText: "{\"file_path\":\"functions/process_sdtm_data.R\"}",
            result: "Session ended", isError: false,
          }],
        },
      ],
    });
    expect(result.current.readingHistory).toBe(false);
    expect(messages(result).some((message) => message.id === "late-read")).toBe(true);
  });

  it("does not let a late history refresh replace a newer live run", async () => {
    const { result } = setup();
    const initialThread = currentThreadId(result);
    const historicalThread = "session-history-race";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Growing history", createdAt: "2026-07-03T00:00:00Z" }],
    });

    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "old-history", role: "user", content: [{ type: "text", text: "old" }] }],
    });
    await act(async () => result.current.runtime.threads.switchToThread(initialThread));
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const refreshRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;
    expect(result.current.readingHistory).toBe(true);

    await act(async () => {
      await result.current.runtime.thread.composer.setText("new live prompt");
      await result.current.runtime.thread.composer.send();
    });
    expect(messages(result).some((message) =>
      message.role === "user" && message.content.some((part) =>
        part.type === "text" && part.text === "new live prompt"))).toBe(true);

    await fireR("load-thread", {
      threadId: historicalThread,
      requestId: refreshRequest.requestId,
      messages: [{ id: "stale-refresh", role: "user", content: [{ type: "text", text: "stale" }] }],
    });

    expect(result.current.readingHistory).toBe(false);
    expect(messages(result).some((message) => message.id === "stale-refresh")).toBe(false);
    expect(messages(result).some((message) =>
      message.role === "user" && message.content.some((part) =>
        part.type === "text" && part.text === "new live prompt"))).toBe(true);
  });

  it("keeps older-page and replacement request guards isolated when responses interleave", async () => {
    const { result } = setup();
    const initialThread = currentThreadId(result);
    const historicalThread = "session-history-interleaved";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Interleaved history", createdAt: "2026-07-04T00:00:00Z" }],
    });

    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const firstRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;
    await fireR("load-thread", {
      threadId: historicalThread, requestId: firstRequest.requestId,
      messages: [{ id: "recent", role: "user", content: [{ type: "text", text: "recent" }] }],
      cursor: 1, hasMore: true,
    });

    await act(async () => result.current.loadOlderHistory());
    const olderRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session_page",
    ).at(-1)!.value;
    await act(async () => result.current.runtime.threads.switchToThread(initialThread));
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const refreshRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;

    await fireR("load-thread", {
      threadId: historicalThread, requestId: olderRequest.requestId, prepend: true,
      messages: [{ id: "older", role: "user", content: [{ type: "text", text: "older" }] }],
      cursor: null, hasMore: false,
    });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("live after older page");
      await result.current.runtime.thread.composer.send();
    });
    await fireR("load-thread", {
      threadId: historicalThread, requestId: refreshRequest.requestId,
      messages: [{ id: "stale-replace", role: "user", content: [{ type: "text", text: "stale" }] }],
    });

    expect(messages(result).some((message) => message.id === "older")).toBe(false);
    expect(messages(result).some((message) => message.id === "stale-replace")).toBe(false);
    expect(messages(result).some((message) => message.role === "user" &&
      message.content.some((part) => part.type === "text" && part.text === "live after older page"))).toBe(true);
  });

  it("ignores an older-page response that arrives after a replacement snapshot", async () => {
    const { result } = setup();
    const initialThread = currentThreadId(result);
    const historicalThread = "session-history-replace-first";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Replace first", createdAt: "2026-07-05T00:00:00Z" }],
    });
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const firstRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;
    await fireR("load-thread", {
      threadId: historicalThread, requestId: firstRequest.requestId,
      messages: [{ id: "recent-old", role: "user", content: [{ type: "text", text: "old snapshot" }] }],
      cursor: 1, hasMore: true,
    });
    await act(async () => result.current.loadOlderHistory());
    const olderRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session_page",
    ).at(-1)!.value;
    await act(async () => result.current.runtime.threads.switchToThread(initialThread));
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const replaceRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;

    await fireR("load-thread", {
      threadId: historicalThread, requestId: replaceRequest.requestId,
      messages: [{ id: "new-snapshot", role: "user", content: [{ type: "text", text: "new snapshot" }] }],
      cursor: 7, hasMore: true,
    });
    await act(async () => result.current.loadOlderHistory());
    const newPageRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session_page",
    ).at(-1)!.value;
    expect(newPageRequest.requestId).not.toBe(olderRequest.requestId);

    // The invalidated old page had no correlation on legacy servers. It must not
    // consume the newly-created page request after replacement completed.
    await fireR("load-thread", {
      threadId: historicalThread, prepend: true,
      messages: [{ id: "obsolete-legacy-older", role: "user", content: [{ type: "text", text: "obsolete" }] }],
      cursor: null, hasMore: false,
    });
    expect(result.current.loadingOlder).toBe(true);
    await fireR("load-thread", {
      threadId: historicalThread, requestId: newPageRequest.requestId, prepend: true,
      messages: [{ id: "new-older", role: "user", content: [{ type: "text", text: "new older" }] }],
      cursor: null, hasMore: false,
    });
    // A correlated response from the invalidated request is stale too.
    await fireR("load-thread", {
      threadId: historicalThread, requestId: olderRequest.requestId, prepend: true,
      messages: [{ id: "obsolete-older", role: "user", content: [{ type: "text", text: "obsolete" }] }],
      cursor: null, hasMore: false,
    });

    expect(messages(result).map((message) => message.id)).toEqual(["new-older", "new-snapshot"]);
    expect(result.current.historyCursor).toBeNull();
    expect(result.current.historyHasMore).toBe(false);
  });

  it("ignores timed-out history responses after a retry starts a newer live run", async () => {
    vi.useFakeTimers();
    try {
      const { result } = setup();
      const initialThread = currentThreadId(result);
      const historicalThread = "session-history-timeout";
      await fireR("sessions", {
        sessions: [{ id: historicalThread, title: "Timeout history", createdAt: "2026-07-05T00:00:00Z" }],
      });
      await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
      const firstRequest = inputs.filter(
        (input) => input.id === "test" && input.value?.type === "load_session",
      ).at(-1)!.value;

      await act(async () => { vi.advanceTimersByTime(15_001); });
      expect(result.current.readingHistory).toBe(false);
      await act(async () => result.current.runtime.threads.switchToThread(initialThread));
      await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
      const retryRequest = inputs.filter(
        (input) => input.id === "test" && input.value?.type === "load_session",
      ).at(-1)!.value;
      expect(retryRequest.requestId).not.toBe(firstRequest.requestId);

      await fireR("load-thread", {
        threadId: historicalThread,
        messages: [{ id: "legacy-timed-out-response", role: "user", content: [{ type: "text", text: "legacy old" }] }],
      });
      expect(result.current.readingHistory).toBe(true);
      expect(messages(result).some((message) => message.id === "legacy-timed-out-response")).toBe(false);

      await act(async () => {
        await result.current.runtime.thread.composer.setText("live after retry");
        await result.current.runtime.thread.composer.send();
      });
      await fireR("load-thread", {
        threadId: historicalThread, requestId: firstRequest.requestId,
        messages: [{ id: "timed-out-response", role: "user", content: [{ type: "text", text: "old" }] }],
      });
      expect(result.current.readingHistory).toBe(true);
      await fireR("load-thread", {
        threadId: historicalThread, requestId: retryRequest.requestId,
        messages: [{ id: "retry-stale-response", role: "user", content: [{ type: "text", text: "retry" }] }],
      });

      expect(result.current.readingHistory).toBe(false);
      expect(messages(result).some((message) => message.id === "timed-out-response")).toBe(false);
      expect(messages(result).some((message) => message.id === "retry-stale-response")).toBe(false);
      expect(messages(result).some((message) => message.role === "user" &&
        message.content.some((part) => part.type === "text" && part.text === "live after retry"))).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("requires request ids after an older-page timeout and retry", async () => {
    vi.useFakeTimers();
    try {
      const { result } = setup();
      const historicalThread = "session-history-page-timeout";
      await fireR("sessions", {
        sessions: [{ id: historicalThread, title: "Page timeout", createdAt: "2026-07-06T00:00:00Z" }],
      });
      await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
      const initialRequest = inputs.filter(
        (input) => input.id === "test" && input.value?.type === "load_session",
      ).at(-1)!.value;
      await fireR("load-thread", {
        threadId: historicalThread, requestId: initialRequest.requestId,
        messages: [{ id: "recent-page", role: "user", content: [{ type: "text", text: "recent" }] }],
        cursor: 10, hasMore: true,
      });

      await act(async () => result.current.loadOlderHistory());
      const firstPageRequest = inputs.filter(
        (input) => input.id === "test" && input.value?.type === "load_session_page",
      ).at(-1)!.value;
      await act(async () => { vi.advanceTimersByTime(15_001); });
      expect(result.current.loadingOlder).toBe(false);
      await act(async () => result.current.loadOlderHistory());
      const retryPageRequest = inputs.filter(
        (input) => input.id === "test" && input.value?.type === "load_session_page",
      ).at(-1)!.value;
      expect(retryPageRequest.requestId).not.toBe(firstPageRequest.requestId);

      await fireR("load-thread", {
        threadId: historicalThread, prepend: true,
        messages: [{ id: "legacy-old-page", role: "user", content: [{ type: "text", text: "legacy" }] }],
        cursor: null, hasMore: false,
      });
      expect(result.current.loadingOlder).toBe(true);
      expect(messages(result).some((message) => message.id === "legacy-old-page")).toBe(false);

      await fireR("load-thread", {
        threadId: historicalThread, requestId: retryPageRequest.requestId, prepend: true,
        messages: [{ id: "retry-page", role: "user", content: [{ type: "text", text: "retry page" }] }],
        cursor: null, hasMore: false,
      });
      expect(result.current.loadingOlder).toBe(false);
      expect(messages(result).some((message) => message.id === "retry-page")).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("ignores history responses that arrive after the thread was deleted", async () => {
    const { result } = setup();
    const historicalThread = "session-history-deleted";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Delete pending", createdAt: "2026-07-06T00:00:00Z" }],
    });
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    const deletedRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    ).at(-1)!.value;
    await act(async () => result.current.runtime.threads.getItemById(historicalThread).delete());

    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "legacy-after-delete", role: "user", content: [{ type: "text", text: "legacy" }] }],
    });
    await fireR("load-thread", {
      threadId: historicalThread, requestId: deletedRequest.requestId,
      messages: [{ id: "correlated-after-delete", role: "user", content: [{ type: "text", text: "correlated" }] }],
    });

    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Reappeared", createdAt: "2026-07-06T00:00:00Z" }],
    });
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "legacy-after-reappear", role: "user", content: [{ type: "text", text: "old legacy" }] }],
    });
    const ids = messages(result).map((message) => message.id);
    expect(ids).not.toContain("legacy-after-delete");
    expect(ids).not.toContain("correlated-after-delete");
    expect(ids).not.toContain("legacy-after-reappear");
  });

  it("hydrates cached history immediately and refreshes it when reopened", async () => {
    const historicalThread = "session-history-cached";
    localStorage.setItem(
      `shinyAssistantUI:test:msgs:${historicalThread}`,
      JSON.stringify([
        { id: "cached-user", role: "user", content: [{ type: "text", text: "cached" }] },
      ]),
    );
    const { result } = setup();
    const initialThread = currentThreadId(result);

    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Cached history", createdAt: "2026-07-02T00:00:00Z" }],
    });
    const loadRequests = () => inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session",
    );
    expect(loadRequests()).toHaveLength(0);

    await act(async () => {
      result.current.runtime.threads.switchToThread(historicalThread);
      result.current.runtime.threads.switchToThread(historicalThread);
    });

    expect(messages(result).some((message) => message.id === "cached-user")).toBe(true);
    expect(loadRequests()).toHaveLength(1);
    expect(loadRequests()[0].value).toMatchObject({
      sessionId: historicalThread,
      threadId: historicalThread,
    });

    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "server-user", role: "user", content: [{ type: "text", text: "authoritative" }] }],
    });
    await act(async () => {
      result.current.runtime.threads.switchToThread(initialThread);
    });
    await act(async () => {
      result.current.runtime.threads.switchToThread(historicalThread);
    });
    expect(loadRequests()).toHaveLength(2);
    expect(result.current.readingHistory).toBe(true);
    expect(messages(result).some((message) => message.id === "server-user")).toBe(true);
  });
});


describe("useShinyRuntime — explicit persistence modes", () => {
  it.each(["server", "none"])(
    "%s mode does not read or write localStorage on the first render",
    async (persistence) => {
      localStorage.setItem(
        "shinyAssistantUI:test:threads",
        JSON.stringify([{ id: "persisted-thread", status: "regular", title: "Persisted" }]),
      );
      localStorage.setItem(
        "shinyAssistantUI:test:msgs:persisted-thread",
        JSON.stringify([{ id: "persisted-message", role: "user", content: [{ type: "text", text: "cached" }] }]),
      );
      const getItem = vi.spyOn(Storage.prototype, "getItem");
      const setItem = vi.spyOn(Storage.prototype, "setItem");
      const removeItem = vi.spyOn(Storage.prototype, "removeItem");

      const { result } = setup({ persistence });
      await act(async () => {});

      expect(currentThreadId(result)).not.toBe("persisted-thread");
      expect(getItem).not.toHaveBeenCalled();
      expect(setItem).not.toHaveBeenCalled();
      expect(removeItem).not.toHaveBeenCalled();
    },
  );

  it.each([undefined, "client"])(
    "%s persistence restores client threads and messages",
    async (persistence) => {
      localStorage.setItem(
        "shinyAssistantUI:test:threads",
        JSON.stringify([{ id: "persisted-thread", status: "regular", title: "Persisted" }]),
      );
      localStorage.setItem(
        "shinyAssistantUI:test:msgs:persisted-thread",
        JSON.stringify([{ id: "persisted-message", role: "user", content: [{ type: "text", text: "cached" }] }]),
      );

      const { result } = setup(persistence ? { persistence } : {});
      await act(async () => {});

      expect(currentThreadId(result)).toBe("persisted-thread");
      expect(messages(result).some((message) => message.id === "persisted-message")).toBe(true);
    },
  );

  it("server mode treats an empty sessions snapshot as authoritative", async () => {
    const { result } = setup({ persistence: "server" });

    await fireR("sessions", {
      sessions: [{ id: "server-history", title: "History", createdAt: "2026-07-01T00:00:00Z" }],
    });
    expect(result.current.runtime.threads.getState().threadIds).toContain("server-history");

    await fireR("sessions", { sessions: [] });
    const state = result.current.runtime.threads.getState();
    expect(state.threadIds).not.toContain("server-history");
    expect(state.mainThreadId).not.toBe("server-history");
  });

  it("方案B：按 archived 标记把会话分流到 active / archived 区", async () => {
    const { result } = setup({ persistence: "server" });
    await fireR("sessions", {
      sessions: [
        { id: "active-1", title: "Active", createdAt: "2026-07-01T00:00:00Z" },
        { id: "arch-1", title: "Archived", createdAt: "2026-07-02T00:00:00Z", archived: true },
      ],
    });
    const state = result.current.runtime.threads.getState();
    expect(state.threadIds).toContain("active-1");
    expect(state.threadIds).not.toContain("arch-1");
    expect(state.archivedThreadIds).toContain("arch-1");
    expect(state.archivedThreadIds).not.toContain("active-1");
  });

  it("方案B：归档一个会话会通知后端持久化软隐藏", async () => {
    const { result } = setup({ persistence: "server" });
    await fireR("sessions", {
      sessions: [{ id: "active-1", title: "Active", createdAt: "2026-07-01T00:00:00Z" }],
    });
    inputs.length = 0;
    await act(async () => {
      await result.current.runtime.threads.getItemById("active-1").archive();
    });
    const arc = inputs.find((i) => i.id === "test_archive_session");
    expect(arc).toBeTruthy();
    expect(arc!.value).toMatchObject({ sessionId: "active-1", archived: true });
  });

  it("方案B：删除 server 会话会通知后端真删磁盘", async () => {
    const { result } = setup({ persistence: "server" });
    await fireR("sessions", {
      sessions: [
        { id: "active-1", title: "One", createdAt: "2026-07-01T00:00:00Z" },
        { id: "active-2", title: "Two", createdAt: "2026-07-02T00:00:00Z" },
      ],
    });
    inputs.length = 0;
    await act(async () => {
      await result.current.runtime.threads.getItemById("active-2").delete();
    });
    const del = inputs.find((i) => i.id === "test_delete_session");
    expect(del).toBeTruthy();
    expect(del!.value).toMatchObject({ sessionId: "active-2" });
  });
});


describe("useShinyRuntime — paged historical sessions", () => {
  it("shows reading state, requests older pages, prepends with id dedupe, and keeps restore separate", async () => {
    const { result } = setup({ persistence: "server" });
    const historicalThread = "paged-history";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Paged", createdAt: "2026-07-03T00:00:00Z" }],
    });

    await act(async () => {
      result.current.runtime.threads.switchToThread(historicalThread);
    });
    expect(result.current.readingHistory).toBe(true);
    expect(result.current.warming).toBe(false);

    const initial = Array.from({ length: 50 }, (_, index) => ({
      id: `m-${index + 51}`, role: "user",
      content: [{ type: "text", text: `message-${index + 51}` }],
    }));
    await fireR("load-thread", {
      threadId: historicalThread,
      messages: initial,
      cursor: 50,
      hasMore: true,
      prepend: false,
    });

    expect(result.current.readingHistory).toBe(false);
    expect(result.current.historyHasMore).toBe(true);
    expect(result.current.loadingOlder).toBe(false);
    expect(messages(result).map((message) => message.id)).toEqual(
      Array.from({ length: 50 }, (_, index) => `m-${index + 51}`),
    );

    await act(async () => result.current.loadOlderHistory());
    const pageRequest = inputs.filter(
      (input) => input.id === "test" && input.value?.type === "load_session_page",
    ).at(-1);
    expect(pageRequest?.value).toMatchObject({
      sessionId: historicalThread,
      threadId: historicalThread,
      cursor: 50,
      limit: 50,
    });
    expect(result.current.loadingOlder).toBe(true);

    const olderWithBoundaryDuplicate = [
      ...Array.from({ length: 50 }, (_, index) => ({
        id: `m-${index + 1}`, role: "user",
        content: [{ type: "text", text: `message-${index + 1}` }],
      })),
      initial[0],
    ];
    await fireR("load-thread", {
      threadId: historicalThread,
      messages: olderWithBoundaryDuplicate,
      cursor: null,
      hasMore: false,
      prepend: true,
    });

    expect(result.current.loadingOlder).toBe(false);
    expect(result.current.historyHasMore).toBe(false);
    const ids = messages(result).map((message) => message.id);
    expect(ids).toHaveLength(100);
    expect(ids[0]).toBe("m-1");
    expect(ids[99]).toBe("m-100");
    expect(new Set(ids).size).toBe(ids.length);

    await fireR("warming", { threadId: historicalThread, active: true });
    expect(result.current.readingHistory).toBe(false);
    expect(result.current.warming).toBe(true);
  });

  it("keeps backward-compatible unpaged load-thread payloads authoritative", async () => {
    const { result } = setup();
    const historicalThread = "legacy-loader";
    await fireR("sessions", {
      sessions: [{ id: historicalThread, title: "Legacy", createdAt: "2026-07-03T00:00:00Z" }],
    });
    await act(async () => result.current.runtime.threads.switchToThread(historicalThread));
    await fireR("load-thread", {
      threadId: historicalThread,
      messages: [{ id: "legacy-message", role: "user", content: [{ type: "text", text: "all" }] }],
    });
    expect(result.current.readingHistory).toBe(false);
    expect(result.current.historyHasMore).toBe(false);
    expect(messages(result).map((message) => message.id)).toEqual(["legacy-message"]);
  });
});


describe("useShinyRuntime — Claude checklist lifecycle", () => {
  async function emitTodoSnapshot(
    result: ReturnType<typeof setup>["result"],
    threadId: string,
    callId: string,
    todos: Array<{ content: string; status: string }>,
  ) {
    await fireR("tool-call", {
      toolCallId: callId,
      toolName: "TodoWrite",
      args: { todos },
      argsText: JSON.stringify({ todos }),
      threadId,
    });
  }

  it("dismisses only the exact completed revision and reopens for changed task state", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("make a checklist");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await emitTodoSnapshot(result, tid, "todo-complete", [
      { content: "finished", status: "completed" },
    ]);

    const completed = result.current.checklist;
    expect(completed?.allCompleted).toBe(true);
    expect(completed?.threadId).toBe(tid);
    await act(async () => result.current.dismissChecklist(tid, completed!.revision));
    expect(result.current.checklist).toBeUndefined();

    await emitTodoSnapshot(result, tid, "todo-next", [
      { content: "new work", status: "pending" },
    ]);
    expect(result.current.checklist?.allCompleted).toBe(false);
    expect(result.current.checklist?.visibleItems[0]?.content).toBe("new work");
  });

  it("automatically hides a completed checklist on the next real user turn and reopens if Claude uses tasks", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("first turn");
      await result.current.runtime.thread.composer.send();
    });
    const tid = currentThreadId(result);
    await emitTodoSnapshot(result, tid, "todo-first", [
      { content: "first done", status: "completed" },
    ]);
    await fireR("done", { threadId: tid });
    expect(result.current.checklist?.allCompleted).toBe(true);

    await act(async () => {
      await result.current.runtime.thread.composer.setText("just answer a follow-up");
      await result.current.runtime.thread.composer.send();
    });
    expect(result.current.checklist).toBeUndefined();

    await emitTodoSnapshot(result, tid, "todo-followup", [
      { content: "follow-up task", status: "in_progress" },
    ]);
    expect(result.current.checklist?.visibleItems[0]?.content).toBe("follow-up task");
  });

  it("keeps dismissed revisions isolated by thread", async () => {
    const { result } = setup();
    await act(async () => {
      await result.current.runtime.thread.composer.setText("thread A");
      await result.current.runtime.thread.composer.send();
    });
    const threadA = currentThreadId(result);
    await emitTodoSnapshot(result, threadA, "todo-a", [
      { content: "A done", status: "completed" },
    ]);
    const revisionA = result.current.checklist!.revision;
    await act(async () => result.current.dismissChecklist(threadA, revisionA));
    expect(result.current.checklist).toBeUndefined();

    await act(async () => result.current.switchToNewThread());
    const threadB = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("thread B");
      await result.current.runtime.thread.composer.send();
    });
    await emitTodoSnapshot(result, threadB, "todo-b", [
      { content: "B done", status: "completed" },
    ]);
    expect(result.current.checklist?.threadId).toBe(threadB);

    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.checklist).toBeUndefined();
  });
});


describe("useShinyRuntime — authoritative cross-thread run phases", () => {
  it("shows Stop only for server-confirmed running, not queued or connecting", async () => {
    const { result } = setup({ run_state_protocol: 1 });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("phase me");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = inputs.find((item) => item.id === "test")!.value;
    const threadId = outbound.threadId as string;
    const runId = outbound.runId as string;

    expect(result.current.runPhase).toBe("connecting");
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);

    await fireR("run-state", { threadId, runId, phase: "queued", queuePosition: 1 });
    expect(result.current.runPhase).toBe("queued");
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);

    await fireR("run-state", { threadId, runId, phase: "connecting" });
    expect(result.current.runPhase).toBe("connecting");
    expect(result.current.runtime.thread.getState().isRunning).toBe(false);

    await fireR("run-state", { threadId, runId, phase: "running" });
    expect(result.current.runPhase).toBe("running");
    expect(result.current.runtime.thread.getState().isRunning).toBe(true);
  });

  it("stores phase badges and transient backend UI independently by thread", async () => {
    const { result } = setup({ run_state_protocol: 1 });
    const threadA = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("A run");
      await result.current.runtime.thread.composer.send();
    });
    const runA = inputs.find((item) => item.id === "test")!.value.runId as string;

    await act(async () => result.current.switchToNewThread());
    const threadB = currentThreadId(result);
    await fireR("run-state", { threadId: threadA, runId: runA, phase: "running" });
    await fireR("suggestions", { threadId: threadA, suggestions: ["Continue A"] });
    await fireR("status", { threadId: threadA, status: "working", text: "A working" });
    await fireR("rate-limit", { threadId: threadA, status: "limited", utilization: 0.9 });
    await fireR("artifact", {
      threadId: threadA, id: "artifact-A", title: "A report", type: "text", content: "A",
    });

    expect(result.current.runPhase).toBeUndefined();
    expect(result.current.statusText).toBeNull();
    expect(result.current.rateLimit).toBeNull();
    expect(result.current.artifacts).toEqual([]);

    await act(async () => result.current.runtime.threads.switchToThread(threadA));
    expect(result.current.runPhase).toBe("running");
    expect(result.current.statusText).toBe("A working");
    expect(result.current.rateLimit).toMatchObject({ status: "limited" });
    expect(result.current.artifacts.map((artifact) => artifact.id)).toEqual(["artifact-A"]);
    expect(result.current.runtime.thread.getState().suggestions)
      .toEqual([expect.objectContaining({ prompt: "Continue A" })]);

    expect(result.current.runPhases[threadA]).toBe("running");
    expect(result.current.runPhases[threadB]).toBeUndefined();
  });

  it("ignores a stale server phase for an older same-thread run", async () => {
    const { result } = setup({ run_state_protocol: 1 });
    await act(async () => {
      await result.current.runtime.thread.composer.setText("current");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = inputs.find((item) => item.id === "test")!.value;
    await fireR("run-state", {
      threadId: outbound.threadId, runId: "older", phase: "complete",
    });
    expect(result.current.runPhase).toBe("connecting");
    expect(result.current.runtime.thread.composer.getState().canSend).toBe(false);
  });
});

  it("archives an active thread only after sending an isolated cancel", async () => {
    const { result } = setup({ persistence: "server", run_state_protocol: 1 });
    await fireR("sessions", {
      sessions: [{ id: "active-run", title: "Active run", createdAt: "2026-07-01T00:00:00Z" }],
    });
    await act(async () => result.current.runtime.threads.switchToThread("active-run"));
    await act(async () => {
      await result.current.runtime.thread.composer.setText("keep running");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = inputs.find((item) => item.id === "test")!.value;
    await fireR("run-state", {
      threadId: "active-run", runId: outbound.runId, phase: "running",
    });
    inputs.length = 0;

    await act(async () => {
      await result.current.runtime.threads.getItemById("active-run").archive();
    });
    expect(inputs.find((item) => item.id === "test_cancel")?.value)
      .toMatchObject({ threadId: "active-run" });
    expect(inputs.find((item) => item.id === "test_archive_session")?.value)
      .toMatchObject({ sessionId: "active-run", archived: true });
  });

  it("deleting a running thread clears its phase and rejects late phase recreation", async () => {
    const { result } = setup({ run_state_protocol: 1 });
    const threadId = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("delete while running");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = inputs.find((item) => item.id === "test")!.value;
    const runId = outbound.runId as string;
    await fireR("run-state", { threadId, runId, phase: "running" });
    expect(result.current.runPhases[threadId]).toBe("running");
    inputs.length = 0;

    await act(async () => {
      await result.current.runtime.threads.getItemById(threadId).delete();
    });
    expect(inputs.find((item) => item.id === "test_cancel")?.value)
      .toMatchObject({ threadId });
    expect(result.current.runPhases[threadId]).toBeUndefined();

    await fireR("run-state", { threadId, runId, phase: "running" });
    expect(result.current.runPhases[threadId]).toBeUndefined();
  });


it("cancelled backend settlement releases the same thread for another run", async () => {
  const { result } = setup({ run_state_protocol: 1 });
  await act(async () => {
    await result.current.runtime.thread.composer.setText("first cancellable");
    await result.current.runtime.thread.composer.send();
  });
  const first = inputs.find((item) => item.id === "test")!.value;
  await fireR("run-state", {
    threadId: first.threadId, runId: first.runId, phase: "cancelled",
  });
  await fireR("done", {
    threadId: first.threadId, runId: first.runId, suggestions: [], cancelled: true,
  });
  expect(result.current.runPhase).toBe("cancelled");

  inputs.length = 0;
  await act(async () => {
    await result.current.runtime.thread.composer.setText("second after cancel");
    await result.current.runtime.thread.composer.send();
  });
  expect(inputs.find((item) => item.id === "test")?.value.text)
    .toBe("second after cancel");
});


it("archiving drops readiness-deferred submissions before service recovery", async () => {
  const { result } = setupCopilot();
  const threadId = currentThreadId(result);
  await fireR("copilot-service-status", { status: "failed", autoStart: true });
  await act(async () => {
    await result.current.runtime.thread.composer.setText("must never dispatch");
    await result.current.runtime.thread.composer.send();
  });
  expect(result.current.pendingServiceSubmissions).toBe(1);
  inputs.length = 0;
  await act(async () => {
    await result.current.runtime.threads.getItemById(threadId).archive();
  });
  expect(result.current.pendingServiceSubmissions).toBe(0);
  await fireR("copilot-service-status", { status: "ready", autoStart: true });
  expect(inputs.filter((item) => item.id === "test")).toHaveLength(0);
  expect(inputs.some((item) => item.id === "test_cancel_reserved_submissions")).toBe(true);
});


describe("useShinyRuntime — Claude Workspace projects", () => {
  const workspaceConfig = {
    workspace_mode: true,
    persistence: "server",
    working_dir: "/work/a",
    run_state_protocol: 1,
  };

  it("preserves session project metadata in ExternalStore custom", async () => {
    const { result } = setup(workspaceConfig);
    await fireR("sessions", {
      sessions: [{
        id: "session-a", title: "A", preview: "", createdAt: "2026-08-01T00:00:00Z",
        project: "/work/a", projectLabel: "Project A",
      }],
    });

    expect(result.current.runtime.threads.getItemById("session-a").getState().custom)
      .toMatchObject({ project: "/work/a", projectLabel: "Project A" });
  });

  it("snapshots the selected project for new threads and immediate submissions", async () => {
    const { result } = setup(workspaceConfig);
    const firstThread = currentThreadId(result);
    expect(result.current.runtime.threads.getItemById(firstThread).getState().custom)
      .toMatchObject({ project: "/work/a" });

    await act(async () => {
      await result.current.runtime.thread.composer.setText("from A");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.find((event) => event.id === "test")?.value)
      .toMatchObject({ threadId: firstThread, project: "/work/a" });

    await fireR("working-dir", { dir: "/work/b", recent: [] });
    await act(async () => result.current.switchToNewThread());
    const secondThread = currentThreadId(result);
    expect(result.current.runtime.threads.getItemById(secondThread).getState().custom)
      .toMatchObject({ project: "/work/b" });
  });

  it("keeps all project threads when the workspace selection changes", async () => {
    const { result } = setup(workspaceConfig);
    await fireR("sessions", {
      sessions: [
        { id: "a-1", title: "A", project: "/work/a", projectLabel: "A" },
        { id: "b-1", title: "B", project: "/work/b", projectLabel: "B" },
      ],
    });
    await fireR("working-dir", { dir: "/work/b", recent: [] });

    const state = result.current.runtime.threads.getState();
    expect(state.threadIds).toEqual(expect.arrayContaining(["a-1", "b-1"]));
  });

  it("keeps a deferred submission bound to its click-time project", async () => {
    const { result } = setup({
      ...workspaceConfig,
      addons: {
        copilotService: { version: 1, state: { status: "checking", autoStart: true } },
      },
    });
    await fireR("copilot-service-status", { status: "checking", autoStart: true });

    await act(async () => {
      await result.current.runtime.thread.composer.setText("queued in A");
      await result.current.runtime.thread.composer.send();
    });
    expect(inputs.filter((event) => event.id === "test")).toHaveLength(0);

    await fireR("working-dir", { dir: "/work/b", recent: [] });
    await fireR("copilot-service-status", { status: "ready", autoStart: true });

    expect(inputs.find((event) => event.id === "test")?.value)
      .toMatchObject({ text: "queued in A", project: "/work/a" });
  });

  it("projects active run and Task counts into thread custom metadata", async () => {
    const { result } = setup(workspaceConfig);
    const threadId = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("count work");
      await result.current.runtime.thread.composer.send();
    });
    const outbound = inputs.find((event) => event.id === "test")!.value;
    await fireR("run-state", { threadId, runId: outbound.runId, phase: "running" });
    await fireR("task", {
      threadId, runId: outbound.runId, taskId: "task-1", kind: "task",
      description: "Work", status: "running",
    });

    expect(result.current.runtime.threads.getItemById(threadId).getState().custom)
      .toMatchObject({ project: "/work/a", runPhase: "running", activeTaskCount: 1 });
  });
});


describe("useShinyRuntime — Workspace routing regressions", () => {
  const config = {
    workspace_mode: true,
    persistence: "server",
    working_dir: "/work/a",
    run_state_protocol: 1,
    action_items: [{ id: "context", command: "context", label: "Context" }],
  };

  it("dispatches ready-gated submissions for different threads concurrently", async () => {
    const { result } = setup({
      ...config,
      addons: { copilotService: { version: 1, state: { status: "checking", autoStart: true } } },
    });
    await fireR("copilot-service-status", { status: "checking", autoStart: true });
    const threadA = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("queued A");
      await result.current.runtime.thread.composer.send();
      result.current.switchToNewThread();
    });
    const threadB = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("queued B");
      await result.current.runtime.thread.composer.send();
    });

    await fireR("copilot-service-status", { status: "ready", autoStart: true });
    const outbound = inputs.filter((item) => item.id === "test");
    expect(outbound.map((item) => item.value.text)).toEqual(["queued A", "queued B"]);
    expect(new Set(outbound.map((item) => item.value.threadId)))
      .toEqual(new Set([threadA, threadB]));
  });

  it("keeps the queued project command expansion captured before project switching", async () => {
    const { result } = setup({
      ...config,
      commands: [{ name: "skill", prompt: "PROMPT_A", description: "A" }],
    });
    const threadA = currentThreadId(result);
    await act(async () => {
      await result.current.runtime.thread.composer.setText("running A");
      await result.current.runtime.thread.composer.send();
      result.current.enqueueMessage("/skill");
    });
    const first = inputs.find((item) => item.id === "test")!.value;
    await fireR("working-dir", { dir: "/work/b", recent: [] });
    await fireR("commands", {
      commands: [{ name: "skill", prompt: "PROMPT_B", description: "B" }],
    });
    await fireR("done", { threadId: threadA, runId: first.runId });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 60)); });

    expect(inputs.filter((item) => item.id === "test").map((item) => item.value.text))
      .toEqual(["running A", "PROMPT_A"]);
  });

  it("forwards the owning project for warmup, action, open-file, and reload", async () => {
    const { result } = setup(config);
    const threadA = currentThreadId(result);
    expect(inputs.find((item) => item.id === "test_warmup")?.value)
      .toMatchObject({ threadId: threadA, project: "/work/a" });

    await act(async () => result.current.invokeAction({ id: "context", label: "Context" }));
    expect(inputs.find((item) => item.id === "test_action")?.value)
      .toMatchObject({ threadId: threadA, project: "/work/a" });

    await act(async () => result.current.openFile("R/app.R", 4));
    expect(inputs.find((item) => item.id === "test_open_file")?.value)
      .toMatchObject({ threadId: threadA, project: "/work/a" });

    await act(async () => {
      await result.current.runtime.thread.composer.setText("reload me");
      await result.current.runtime.thread.composer.send();
    });
    const sent = inputs.filter((item) => item.id === "test").at(-1)!.value;
    await fireR("chunk", { text: "answer", threadId: threadA });
    await fireR("done", { threadId: threadA, runId: sent.runId });
    const assistant = messages(result).find((message) => message.role === "assistant")!;
    await act(async () => result.current.runtime.thread.getMessageById(assistant.id).reload());
    expect(inputs.filter((item) => item.id === "test" && item.value.type === "reload").at(-1)?.value)
      .toMatchObject({ threadId: threadA, project: "/work/a" });
  });
});
