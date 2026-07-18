// useShinyRuntime — ExternalStoreRuntime + 多线程 + localStorage 持久化
// Module-level map: thread ID → formatted date string for sidebar display
export const sessionDates = new Map<string, string>();

import { useRef, useCallback, useState, useEffect, useMemo } from "react";
import {
  useExternalStoreRuntime, WebSpeechDictationAdapter, WebSpeechSynthesisAdapter,
  SimpleImageAttachmentAdapter, SimpleTextAttachmentAdapter, CompositeAttachmentAdapter,
} from "@assistant-ui/react";
import type {
  ThreadMessageLike,
  AppendMessage,
  ExternalStoreThreadData,
  StartRunConfig,
  FeedbackAdapter,
} from "@assistant-ui/core";
import { createShinyBridge } from "./bridge";
import type { ShinyBridge, SessionItem } from "./bridge";
import type { PermissionModeOption, PermissionModeState } from "./shiny-config-context";
import {
  storageKey, makeThreadId, markStaleToolCalls, stripAttachmentData,
  extractAttachments, expandSlashCommands, applyEdit, matchSlashAction,
} from "./helpers";

// ── 持久化 key ──────────────────────────────────────────────────────────────

function loadThreads(inputId: string): ExternalStoreThreadData<"regular">[] {
  try {
    const raw = localStorage.getItem(storageKey(inputId, "threads"));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveThreads(inputId: string, threads: ExternalStoreThreadData<"regular">[]) {
  try {
    localStorage.setItem(storageKey(inputId, "threads"), JSON.stringify(threads));
  } catch (e) {
    console.warn("[shinyAssistantUI] saveThreads failed:", e);
  }
}

function loadArchivedThreads(inputId: string): ExternalStoreThreadData<"archived">[] {
  try {
    const raw = localStorage.getItem(storageKey(inputId, "archived"));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveArchivedThreads(inputId: string, threads: ExternalStoreThreadData<"archived">[]) {
  try {
    localStorage.setItem(storageKey(inputId, "archived"), JSON.stringify(threads));
  } catch (e) {
    console.warn("[shinyAssistantUI] saveArchivedThreads failed:", e);
  }
}

// 把所有未完成（result === undefined）的 tool-call part 标记为中断。
// markStaleToolCalls 已抽到 ./helpers，此处仅保留 localStorage 读写包装。

function loadMessages(inputId: string, threadId: string): ThreadMessageLike[] {
  try {
    const raw = localStorage.getItem(storageKey(inputId, `msgs:${threadId}`));
    if (!raw) return [];
    const msgs = JSON.parse(raw) as ThreadMessageLike[];
    // Any tool-call part without a result is stale (session ended mid-run) — mark as interrupted
    return markStaleToolCalls(msgs, "Session ended").messages;
  } catch {
    return [];
  }
}

// 落盘前剥离附件大体积 base64 data（stripAttachmentData 已抽到 ./helpers）。
function saveMessages(inputId: string, threadId: string, msgs: ThreadMessageLike[]) {
  try {
    const slim = stripAttachmentData(msgs);
    localStorage.setItem(storageKey(inputId, `msgs:${threadId}`), JSON.stringify(slim));
  } catch (e) {
    // 配额超限等：不再完全静默，至少告警（数据仅当前会话内存可见，刷新丢失）
    console.warn(`[shinyAssistantUI] saveMessages failed (thread ${threadId}):`, e);
  }
}

function deleteMessages(inputId: string, threadId: string) {
  try {
    localStorage.removeItem(storageKey(inputId, `msgs:${threadId}`));
  } catch {}
}

// makeThreadId / extractAttachments / expandSlashCommands 已抽到 ./helpers

// ── hook ────────────────────────────────────────────────────────────────────

type CommandDef = { name: string; description: string; prompt: string; category?: string };
type ActionItemDef = { id: string; command?: string; label?: string; section?: string; description?: string };
const AVAILABLE_PERMISSION_MODES = new Set([
  "default", "plan", "acceptEdits", "bypassPermissions",
]);

export function useShinyRuntime(inputId: string, config: Record<string, unknown>) {
  // 从 config 提取 commands，用于 /commandName → cmd.prompt 展开（useMemo 稳定引用）
  const commands = useMemo(
    () => (config?.commands as CommandDef[] | undefined) ?? [],
    [config],
  );
  const actionItems = useMemo(
    () => (config?.action_items as ActionItemDef[] | undefined) ?? [],
    [config],
  );
  const permissionCapability = useMemo(() => {
    const capabilities = config?.ui_capabilities as Record<string, unknown> | undefined;
    const raw = capabilities?.permission_mode as
      | { value?: unknown; options?: unknown }
      | undefined;
    if (typeof raw?.value !== "string" || !Array.isArray(raw.options)) return undefined;
    const options = raw.options.filter((option): option is PermissionModeOption => {
      if (!option || typeof option !== "object") return false;
      const candidate = option as Record<string, unknown>;
      return typeof candidate.value === "string" && typeof candidate.label === "string";
    });
    return { value: raw.value, options };
  }, [config]);
  // 懒初始化：避免每次 render 都调用 createShinyBridge（会重复注册 Shiny handler
  // 覆盖旧的，但 useRef 还是返回第一个 bridge，导致 handler 和 callbacks 对应的闭包不一致）
  const bridge = useRef<ShinyBridge>(null!);
  if (!bridge.current) {
    bridge.current = createShinyBridge(inputId);
  }

  // 历史 session 线程中尚未从 R 加载消息的 thread_id 集合（lazy load）
  const unloadedSessionIds = useRef(new Set<string>());
  // 稳定 ref，供注册一次的 onSessions 回调读取当前 threadId（绕过 stale closure）
  const currentThreadIdRef = useRef<string>("");
  // 本次 React 实例（页面加载后）新建的线程 ID 集合。
  // onSessions 到达时用 server 列表替换 localStorage 线程，但保留这些本地新建线程，
  // 避免把用户正在进行的对话丢掉。
  const thisSessionThreadIds = useRef(new Set<string>());
  // server 端调用 send_sessions 后置为 true：消息不再写 localStorage，server 为唯一 truth
  const isServerMode = useRef(false);

  // 反馈适配器（稳定引用，通过 bridge 发送到 R 端）
  const feedbackAdapter = useRef<FeedbackAdapter>({
    submit: ({ message, type }) => {
      bridge.current.sendFeedback(message.id, type === "positive" ? "positive" : "negative");
    },
  });

  // 文件上传适配器（image + 纯文本，稳定引用）
  const attachmentAdapter = useRef<CompositeAttachmentAdapter>(null!);
  if (!attachmentAdapter.current) {
    attachmentAdapter.current = new CompositeAttachmentAdapter([
      new SimpleImageAttachmentAdapter(),
      new SimpleTextAttachmentAdapter(),
    ]);
  }

  // 线程列表（持久化）
  const [threads, setThreads] = useState<ExternalStoreThreadData<"regular">[]>(() =>
    loadThreads(inputId)
  );

  // 归档线程列表（持久化）
  const [archivedThreads, setArchivedThreads] = useState<ExternalStoreThreadData<"archived">[]>(() =>
    loadArchivedThreads(inputId)
  );

  // 当前 threadId
  const [currentThreadId, setCurrentThreadId] = useState<string>(() => {
    const saved = loadThreads(inputId);
    if (saved.length > 0) return saved[0].id; // 来自 localStorage（上次运行），不追踪
    const id = makeThreadId();
    thisSessionThreadIds.current.add(id);       // 本次新建，追踪
    return id;
  });
  // 每次 render 更新 ref，让注册一次的回调（onSessions 等）始终读到最新值
  currentThreadIdRef.current = currentThreadId;

  // 确保初始线程在列表里
  useEffect(() => {
    setThreads((prev) => {
      if (prev.some((t) => t.id === currentThreadId)) return prev;
      const next = [
        { id: currentThreadId, status: "regular" as const, title: "新对话" },
        ...prev,
      ];
      saveThreads(inputId, next);
      return next;
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // 消息 Map（threadId → messages）
  const [messagesMap, setMessagesMap] = useState<Record<string, ThreadMessageLike[]>>(() => {
    const saved = loadThreads(inputId);
    const map: Record<string, ThreadMessageLike[]> = {};
    const ids = saved.length > 0 ? saved.map((t) => t.id) : [currentThreadId];
    for (const id of ids) {
      map[id] = loadMessages(inputId, id);
    }
    return map;
  });

  const [isRunning, setIsRunning] = useState(false);
  const [suggestions, setSuggestions] = useState<Array<{prompt: string}>>([]);
  // Artifacts 侧面板:会话级(不持久化)。type ∈ markdown/code/html/text
  const [artifacts, setArtifacts] = useState<Array<{ id: string; title: string; type: string; content: string; lang?: string }>>([]);
  const [activeArtifactId, setActiveArtifactId] = useState<string | null>(null);

  // ── ClaudeAgentSDK 能力对齐状态 ────────────────────────────────────────────
  type UsageInfo = { costUsd?: number; tokens?: number; turns?: number; durationMs?: number; model?: string };
  type TaskInfo = { taskId: string; kind: string; description?: string; status?: string; toolName?: string; summary?: string };
  const [usageMap, setUsageMap] = useState<Record<string, UsageInfo>>({});          // #1 每线程最新用量
  const [tasksMap, setTasksMap] = useState<Record<string, Record<string, TaskInfo>>>({}); // #2 每线程 taskId→info
  const [rateLimit, setRateLimit] = useState<{ status?: string; resetsAt?: string; utilization?: number; type?: string } | null>(null); // #3
  const [statusText, setStatusText] = useState<string | null>(null);                // #4 当前状态行
  const [warmingThreads, setWarmingThreads] = useState<Set<string>>(new Set());      // 每线程冷启动中
  const [serverCommands, setServerCommands] = useState<Array<{ name: string; description?: string }>>([]); // #5
  const streamingIdRef  = useRef<string | null>(null);
  const manualTitleIds  = useRef<Set<string>>(new Set()); // 用户手动重命名过的线程
  const messageQueueRef = useRef<Map<string, string[]>>(new Map()); // 每线程排队消息
  const actionAckRefs = useRef(new Map<string, { threadId: string; ackId: string }>());
  const invokeActionRef = useRef<((item: ActionItemDef) => void) | null>(null);
  const actionRequestSeq = useRef(0);
  type PermissionPending = { requestId: string; requested: string };
  const [permissionValues, setPermissionValues] = useState<Record<string, string>>({});
  const [permissionPending, setPermissionPending] = useState<Record<string, PermissionPending>>({});
  const [permissionErrors, setPermissionErrors] = useState<Record<string, string | null>>({});
  const permissionPendingRef = useRef<Record<string, PermissionPending>>({});
  const permissionRequestsRef = useRef(new Map<string, { threadId: string; requested: string }>());
  const makeActionRequestId = () => `action-${Date.now()}-${++actionRequestSeq.current}`;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const deliverTextRef  = useRef<((text: string, threadId: string) => void) | null>(null);
  const hasReasoningRef = useRef(false); // thinking arrived before text chunks
  // 正在 streaming 的 threadId 集合（含后台并发 run）。用于：
  // ① 多 tab storage 同步时保护正在跑的线程不被磁盘旧值覆盖；
  const activeRunsRef = useRef<Set<string>>(new Set());
  // per-thread run 序号，用于 onDone/onError 判断自己是否仍是该线程最新的 run，
  // 避免 run 重入时旧 run 的收尾逻辑误删新 run 的 callbacks。
  const runSeqRef = useRef<Record<string, number>>({});

  // 多 tab 同步：监听 storage 事件（仅其它 tab 写同源 localStorage 时触发，本 tab 不触发）。
  // 避免两个 tab 各持独立 state、last-write-wins 互相覆盖对方新建/删除的线程。
  // 策略：threads/archived 列表直接 reload 保持侧栏一致；某 thread 的消息仅在它
  // 不在本 tab 正在 streaming 时才同步（正在跑的线程本地领先磁盘，防覆盖流式中消息）。
  useEffect(() => {
    if (isServerMode.current) return; // server 权威模式不用 localStorage
    const prefix = storageKey(inputId, "");
    const onStorage = (e: StorageEvent) => {
      if (isServerMode.current || !e.key || !e.key.startsWith(prefix)) return;
      const suffix = e.key.slice(prefix.length);
      if (suffix === "threads") {
        setThreads(loadThreads(inputId));
      } else if (suffix === "archived") {
        setArchivedThreads(loadArchivedThreads(inputId));
      } else if (suffix.startsWith("msgs:")) {
        const tid = suffix.slice("msgs:".length);
        // 正在 streaming 的线程（含后台并发 run）本地领先磁盘，跳过同步防覆盖；
        // 当前活动线程也跳过（用户正在看/可能将发消息）。
        if (activeRunsRef.current.has(tid) || tid === currentThreadIdRef.current) return;
        setMessagesMap((prev) => ({ ...prev, [tid]: loadMessages(inputId, tid) }));
      }
    };
    window.addEventListener("storage", onStorage);
    return () => window.removeEventListener("storage", onStorage);
  }, [inputId]);

  // 当前线程消息
  const messages = useMemo(
    () => messagesMap[currentThreadId] ?? [],
    [messagesMap, currentThreadId]
  );

  // 更新消息并持久化（server mode 下跳过写 localStorage）
  const setCurrentMessages = useCallback(
    (updater: (prev: ThreadMessageLike[]) => ThreadMessageLike[]) => {
      setMessagesMap((prev) => {
        const updated = updater(prev[currentThreadId] ?? []);
        if (!isServerMode.current) saveMessages(inputId, currentThreadId, updated);
        return { ...prev, [currentThreadId]: updated };
      });
    },
    [inputId, currentThreadId]
  );

  // ── 切换到第一个可用线程或新建 ────────────────────────────────────────────
  const switchAwayFrom = useCallback(
    (removedId: string, currentThreads: ExternalStoreThreadData<"regular">[]) => {
      const remaining = currentThreads.filter((t) => t.id !== removedId);
      if (remaining.length > 0) {
        setCurrentThreadId(remaining[0].id);
      } else {
      const newId = makeThreadId();
        thisSessionThreadIds.current.add(newId);
        const newThread: ExternalStoreThreadData<"regular"> = {
          id: newId,
          status: "regular",
          title: "新对话",
        };
        setThreads((prev) => {
          const next = [newThread, ...prev.filter((t) => t.id !== removedId)];
          saveThreads(inputId, next);
          return next;
        });
        setCurrentThreadId(newId);
      }
      setIsRunning(false);
      streamingIdRef.current = null;
    },
    [inputId]
  );

  // ── 注册 clear（新建线程）────────────────────────────────────────────────
  useEffect(() => {
    bridge.current.onClear(() => {
      const newId = makeThreadId();
      thisSessionThreadIds.current.add(newId);
      const newThread: ExternalStoreThreadData<"regular"> = {
        id: newId,
        status: "regular",
        title: "新对话",
      };
      setThreads((prev) => {
        const next = [newThread, ...prev];
        saveThreads(inputId, next);
        return next;
      });
      setCurrentThreadId(newId);
      setIsRunning(false);
      streamingIdRef.current = null;
    });

    // ── 注册 :action-result（permission 静默状态 / 普通动作 ack）───────────────
    bridge.current.onActionResult((result) => {
      const requestId = result.requestId;
      const permissionRequest = requestId
        ? permissionRequestsRef.current.get(requestId)
        : undefined;
      if (permissionRequest) {
        const { threadId: tid, requested } = permissionRequest;
        const latest = permissionPendingRef.current[tid];
        if (!latest || latest.requestId !== requestId) {
          permissionRequestsRef.current.delete(requestId!);
          return;
        }
        if (result.status === "progress") return;
        permissionRequestsRef.current.delete(requestId!);

        if (result.status === "error") {
          setPermissionErrors((prev) => ({
            ...prev,
            [tid]: result.message || "Permission mode request failed",
          }));
        } else if (result.status !== "progress") {
          const canonical = typeof result.value === "string" ? result.value : requested;
          setPermissionValues((prev) => ({ ...prev, [tid]: canonical }));
          setPermissionErrors((prev) => ({ ...prev, [tid]: null }));
        } else {
          return;
        }
        const nextPending = { ...permissionPendingRef.current };
        delete nextPending[tid];
        permissionPendingRef.current = nextPending;
        setPermissionPending(nextPending);
        return;
      }

      const target = requestId ? actionAckRefs.current.get(requestId) : undefined;
      if (!target || !result.message) return;
      const prefix = result.status === "error" ? "\u26a0\ufe0f "
        : result.status === "progress" ? "\u23f3 "
        : "\u2713 ";
      setMessagesMap((prev) => {
        const msgs = prev[target.threadId] ?? [];
        const updated = msgs.map((m): ThreadMessageLike =>
          m.id === target.ackId
            // eslint-disable-next-line @typescript-eslint/no-explicit-any
            ? ({ ...m, content: [{ type: "text" as const, text: prefix + result.message }] } as any)
            : m,
        );
        if (!isServerMode.current) saveMessages(inputId, target.threadId, updated);
        return { ...prev, [target.threadId]: updated };
      });
      if (result.status !== "progress") actionAckRefs.current.delete(requestId!);
      const effect = result.value && typeof result.value === "object"
        ? (result.value as { effect?: unknown }).effect
        : undefined;
      if (result.status !== "error" && result.status !== "progress" &&
          effect === "new-thread" && target.threadId === currentThreadIdRef.current) {
        switchToNewThread();
      }
    });

    // ── #1 用量/成本 ─────────────────────────────────────────────────────────
    bridge.current.onUsage((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setUsageMap((prev) => ({ ...prev, [tid]: {
        costUsd: d.costUsd, tokens: d.tokens, turns: d.turns, durationMs: d.durationMs, model: d.model,
      } }));
    });
    // ── #2 子agent/Task 进度 ──────────────────────────────────────────────────
    bridge.current.onTask((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setTasksMap((prev) => {
        const forThread = { ...(prev[tid] ?? {}) };
        // notification 且 status 为终态 → 保留但标记;其余 upsert
        forThread[d.taskId] = {
          ...(forThread[d.taskId] ?? { taskId: d.taskId }),
          taskId: d.taskId, kind: d.kind,
          description: d.description ?? forThread[d.taskId]?.description,
          status: d.status ?? forThread[d.taskId]?.status,
          toolName: d.toolName ?? forThread[d.taskId]?.toolName,
          summary: d.summary ?? forThread[d.taskId]?.summary,
        };
        return { ...prev, [tid]: forThread };
      });
    });
    // ── #3 限流告警 ───────────────────────────────────────────────────────────
    bridge.current.onRateLimit((d) => {
      // status 正常(allowed/ok)时清除 banner;受限时显示
      const limited = d.status && !/^(allowed|ok|none)$/i.test(d.status);
      setRateLimit(limited ? { status: d.status, resetsAt: d.resetsAt, utilization: d.utilization, type: d.type } : null);
    });
    // ── #4 系统状态行 ─────────────────────────────────────────────────────────
    bridge.current.onStatus((d) => {
      const label = d.text || (d.status === "thinking_tokens" ? "Thinking\u2026"
        : d.status === "init" ? "Initializing\u2026" : d.status);
      setStatusText(label ?? null);
    });
    // ── 每线程冷启动指示 ──────────────────────────────────────────────────────
    bridge.current.onWarming((d) => {
      const tid = d.threadId ?? currentThreadIdRef.current;
      setWarmingThreads((prev) => {
        const next = new Set(prev);
        if (d.active) next.add(tid); else next.delete(tid);
        return next;
      });
    });
    // ── #5 命令自动发现 ───────────────────────────────────────────────────────
    bridge.current.onServerCommands((d) => {
      const cmds = (d.commands ?? []) as Array<Record<string, unknown>>;
      const mapped = cmds.map((c) => ({
        name: String(c.name ?? c.command ?? ""),
        description: (c.description ?? c.summary) as string | undefined,
      })).filter((c) => c.name);
      if (mapped.length) setServerCommands((prev) => {
        const seen = new Set(prev.map((p) => p.name));
        return [...prev, ...mapped.filter((m) => !seen.has(m.name))];
      });
    });

    // ── 注册 :sessions（侧边栏注入历史 Claude session）─────────────────────
    // 策略：server 列表到达时【替换】localStorage 线程，而非追加。
    // 只保留本次 React 实例新建（thisSessionThreadIds）且尚未在 server 上的线程，
    // 避免旧 localStorage 孤儿线程（t_XXXX）和 server sessions（UUID）同时显示。
    bridge.current.onSessions(({ sessions }: { sessions: SessionItem[] }) => {
      if (sessions.length === 0) return;

      // server 提供了 sessions → 切换到 server-authoritative 模式，消息不再写 localStorage
      isServerMode.current = true;

      const serverIds = new Set(sessions.map((s) => s.id));

      // 填充日期 Map（供侧边栏展示），ISO 字符串直接传入 Date 构造函数
      for (const s of sessions) {
        if (s.createdAt) {
          const d = new Date(s.createdAt);
          if (!isNaN(d.getTime())) {
            sessionDates.set(s.id, d.toLocaleDateString(undefined, {
              year: "numeric", month: "short", day: "numeric",
            }));
          }
        }
      }

      // 标记所有无本地消息的 server session 为待懒加载
      for (const s of sessions) {
        if (loadMessages(inputId, s.id).length === 0) {
          unloadedSessionIds.current.add(s.id);
        }
      }

      const serverThreads: ExternalStoreThreadData<"regular">[] = sessions.map((s) => ({
        id: s.id, status: "regular" as const, title: s.title || s.id,
      }));

      setThreads((prev) => {
        // 保留本次 session 新建且尚未上传 server 的线程（例如用户正在输入）
        const localNew = prev.filter(
          (t) => !serverIds.has(t.id) && thisSessionThreadIds.current.has(t.id)
        );
        // 本地新建线程排前面，server 历史线程排后面
        const merged = [...localNew, ...serverThreads];
        saveThreads(inputId, merged);
        return merged;
      });

      setMessagesMap((prev) => {
        const patch: Record<string, ThreadMessageLike[]> = {};
        for (const s of sessions) {
          patch[s.id] = prev[s.id] ?? loadMessages(inputId, s.id);
        }
        return { ...prev, ...patch };
      });

      // 当前线程若是被替换掉的 localStorage 孤儿线程，切换到第一个 server session
      const cur = currentThreadIdRef.current;
      if (!serverIds.has(cur) && !thisSessionThreadIds.current.has(cur)) {
        setCurrentThreadId(sessions[0].id);
      }

      // 如果当前线程是未加载的 server session，立即触发加载
      const activeCur = serverIds.has(currentThreadIdRef.current)
        ? currentThreadIdRef.current
        : sessions[0].id;
      if (unloadedSessionIds.current.has(activeCur)) {
        bridge.current.sendLoadSession(activeCur, activeCur);
        unloadedSessionIds.current.delete(activeCur);
      }
    });

    // ── 注册 :load-thread（接收 R 发来的历史消息）─────────────────────────
    bridge.current.onLoadThread(({ threadId, messages }: { threadId: string; messages: unknown[] }) => {
      unloadedSessionIds.current.delete(threadId);
      setMessagesMap((prev) => {
        const typedMsgs = messages as ThreadMessageLike[];
        if (!isServerMode.current) saveMessages(inputId, threadId, typedMsgs);
        return { ...prev, [threadId]: typedMsgs };
      });
    });

    // :sessions handler 已注册，通知 R 可以补发 sessions（解决 React 18 异步 render 时序问题）
    bridge.current.sendReady();
    // 预热当前(初始)线程:让 R 后台连接该线程的 client,使首条消息不再冷启动。
    // R 侧仅在 prewarm=TRUE 且 handler 暴露 warmup 时响应(ellmer 等无 warmup → no-op)。
    bridge.current.sendWarmup(currentThreadIdRef.current);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ── 启动一次 streaming run（onNew 和 onReload 共用）────────────────────────
  const startRun = useCallback(
    (threadId: string, sendFn: () => void) => {
      setIsRunning(true);
      setSuggestions([]);
      streamingIdRef.current = null;

      // 登记本 run：active 集合用于多 tab 同步保护；run 序号用于 onDone/onError
      // 判断自己是否仍是该线程最新 run（重入时旧 run 不得误删新 run 的 callbacks）。
      activeRunsRef.current.add(threadId);
      const mySeq = (runSeqRef.current[threadId] ?? 0) + 1;
      runSeqRef.current[threadId] = mySeq;
      const isLatestRun = () => runSeqRef.current[threadId] === mySeq;

      bridge.current.setRunCallbacks(threadId, {
        onThinking: (thinkingText) => {
          // Reasoning part stored INLINE in the same assistant message as text
          if (!streamingIdRef.current) {
            streamingIdRef.current = `assistant-${Date.now()}`;
          }
          const msgId = streamingIdRef.current;
          hasReasoningRef.current = true;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            if (!existing) {
              return {
                ...prev,
                [threadId]: [
                  ...threadMsgs,
                  { id: msgId, role: "assistant" as const, content: [{ type: "reasoning" as const, text: thinkingText }] },
                ],
              };
            }
            // Append to reasoning part
            return {
              ...prev,
              [threadId]: threadMsgs.map((m): ThreadMessageLike => {
                if (m.id !== msgId) return m;
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const content = [...(m.content as any[])];
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const ridx = content.findIndex((p: any) => p.type === "reasoning");
                if (ridx < 0) return m;
                const updated = [...content];
                updated[ridx] = { ...content[ridx], text: content[ridx].text + thinkingText };
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                return { ...m, content: updated } as any;
              }),
            };
          });
        },
        onChunk: (chunkText) => {
          // 在调用 setMessagesMap 前先快照 ID——updater 是异步调度的，若
          // onDone 先于 updater 执行会把 streamingIdRef.current 清为 null，
          // 导致 updater 误判为新消息，产生"末尾碎片"分裂 bubble 的 bug。
          if (!streamingIdRef.current) {
            streamingIdRef.current = `assistant-${Date.now()}`;
          }
          const msgId = streamingIdRef.current;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            let updated: ThreadMessageLike[];
            if (!existing) {
              updated = [
                ...threadMsgs,
                { id: msgId, role: "assistant", content: [{ type: "text", text: chunkText }] },
              ];
            } else {
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = existing.content as any[];
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const tidx = content.findIndex((p: any) => p.type === "text");
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const newContent: any[] = tidx >= 0
                ? content.map((p: { type: string; text: string }, i: number) => i === tidx ? { ...p, text: p.text + chunkText } : p)
                : [...content, { type: "text", text: chunkText }];
              updated = threadMsgs.map((m): ThreadMessageLike =>
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                m.id === msgId ? ({ ...m, content: newContent } as any) : m
              );
            }
            // 流式过程中不写 localStorage——每个 token 都序列化是主要卡顿来源；
            // onDone 时统一持久化即可。
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCallStart: (toolCallId, toolName, annotations) => {
          // 流式工具参数：先建空壳 tool-call part，后续 onToolCallDelta 逐字追加 argsText
          streamingIdRef.current = null;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            if (threadMsgs.find((m) => m.id === `tool-${toolCallId}`)) return prev;
            const updated: ThreadMessageLike[] = [
              ...threadMsgs,
              {
                id: `tool-${toolCallId}`,
                role: "assistant" as const,
                content: [
                  {
                    type: "tool-call" as const,
                    toolCallId,
                    toolName,
                    // eslint-disable-next-line @typescript-eslint/no-explicit-any
                    args: {} as any,
                    argsText: "",
                    artifact: annotations,
                  },
                ],
              },
            ];
            // 流式期间不写 localStorage（仿 onChunk），避免半截参数腐败历史
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCallDelta: (toolCallId, delta) => {
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = threadMsgs.map((m): ThreadMessageLike => {
              if (m.id !== `tool-${toolCallId}`) return m;
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = m.content as any[];
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const cidx = content.findIndex((p: any) => p.type === "tool-call");
              if (cidx < 0) return m;
              const newContent = [...content];
              newContent[cidx] = { ...content[cidx], argsText: (content[cidx].argsText ?? "") + delta };
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              return { ...m, content: newContent } as any;
            });
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCall: (toolCall) => {
          streamingIdRef.current = null;
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === `tool-${toolCall.toolCallId}`);
            let updated: ThreadMessageLike[];
            if (existing) {
              // 已被 onToolCallStart 创建（Claude 流式路径）：补全解析后的 args + artifact，不重复 push
              updated = threadMsgs.map((m): ThreadMessageLike => {
                if (m.id !== `tool-${toolCall.toolCallId}`) return m;
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const content = m.content as any[];
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const cidx = content.findIndex((p: any) => p.type === "tool-call");
                if (cidx < 0) return m;
                const newContent = [...content];
                newContent[cidx] = {
                  ...content[cidx],
                  // eslint-disable-next-line @typescript-eslint/no-explicit-any
                  args: toolCall.args as any,
                  argsText: toolCall.argsText,
                  artifact: toolCall.annotations,
                };
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                return { ...m, content: newContent } as any;
              });
            } else {
              // 无 start（ellmer 路径）：整包新建
              updated = [
                ...threadMsgs,
                {
                  id: `tool-${toolCall.toolCallId}`,
                  role: "assistant" as const,
                  content: [
                    {
                      type: "tool-call" as const,
                      toolCallId: toolCall.toolCallId,
                      toolName: toolCall.toolName,
                      // eslint-disable-next-line @typescript-eslint/no-explicit-any
                      args: toolCall.args as any,
                      argsText: toolCall.argsText,
                      artifact: toolCall.annotations,
                    },
                  ],
                },
              ];
            }
            if (!isServerMode.current) saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onToolResult: (toolCallId, result, isError) => {
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = threadMsgs.map((m): ThreadMessageLike => {
              // 按 type + toolCallId 定位 part（不假设 content[0]），与
              // markStaleToolCalls / onToolCallDelta 保持一致，兼容未来多 part 消息。
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const content = m.content as any[];
              if (!Array.isArray(content)) return m;
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              const cidx = content.findIndex(
                (p: any) => p?.type === "tool-call" && p.toolCallId === toolCallId,
              );
              if (cidx < 0) return m;
              const newContent = [...content];
              newContent[cidx] = { ...content[cidx], result, isError };
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              return { ...m, content: newContent } as any;
            });
            if (!isServerMode.current) saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onSource: (source) => {
          if (!streamingIdRef.current) streamingIdRef.current = `assistant-${Date.now()}`;
          const msgId = streamingIdRef.current;
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = {
            type: "source", sourceType: "url",
            id: source.id ?? `src-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
            url: source.url, title: source.title ?? source.url,
          };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (!isServerMode.current) saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onImage: (image) => {
          if (!streamingIdRef.current) streamingIdRef.current = `assistant-${Date.now()}`;
          const msgId = streamingIdRef.current;
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const part: any = { type: "image", image };
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const existing = threadMsgs.find((m) => m.id === msgId);
            const updated = existing
              // eslint-disable-next-line @typescript-eslint/no-explicit-any
              ? threadMsgs.map((m): ThreadMessageLike => m.id === msgId ? ({ ...m, content: [...(m.content as any[]), part] } as any) : m)
              : [...threadMsgs, { id: msgId, role: "assistant" as const, content: [part] }];
            if (!isServerMode.current) saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onArtifact: (artifact) => {
          setArtifacts((prev) => {
            const idx = prev.findIndex((a) => a.id === artifact.id);
            if (idx >= 0) {
              const next = [...prev];
              next[idx] = artifact;
              return next;
            }
            return [...prev, artifact];
          });
          setActiveArtifactId(artifact.id); // 新/更新的 artifact 自动打开面板
        },
        onDone: (doneSuggestions) => {
          streamingIdRef.current = null;
          hasReasoningRef.current = false;
          // 只有当前 thread 仍是发起此 run 的 thread 时才清 running 状态
          // 避免用户切换 thread 后旧 handler 的 onDone 把新 thread 的 running 错误清掉
          if (currentThreadIdRef.current === threadId) {
            setIsRunning(false);
            setStatusText(null);  // #4 run 结束清状态行
            if (doneSuggestions && doneSuggestions.length > 0) setSuggestions(doneSuggestions);
          }
          // 仅当本 run 仍是该线程最新 run 时才注销 callbacks / 清 active 标记。
          // 避免 run 重入（edit 后立即 reload 等）时旧 run 的 onDone 误删新 run 的 callbacks。
          if (isLatestRun()) {
            activeRunsRef.current.delete(threadId);
            bridge.current.setRunCallbacks(threadId, null);
            // 消息队列 flush：本 run 结束后若该线程有排队消息,自动发送下一条
            const q = messageQueueRef.current.get(threadId);
            if (q && q.length > 0) {
              const nextText = q.shift()!;
              setTimeout(() => deliverTextRef.current?.(nextText, threadId), 40);
            }
          }
          setMessagesMap((prev) => {
            // 收口：把任何未完成的 tool-call part 标记中断。正常结束时无半截卡
            // （changed=false，零影响）；中断 drain 时 R 可能漏发 on_tool_result，
            // 此处兜底避免卡片永久转圈。
            const { messages: msgs, changed } = markStaleToolCalls(
              prev[threadId] ?? [],
              "Interrupted",
            );
            if (!isServerMode.current) saveMessages(inputId, threadId, msgs);
            return changed ? { ...prev, [threadId]: msgs } : { ...prev, [threadId]: prev[threadId] ?? [] };
          });
        },
        onError: (errMsg) => {
          streamingIdRef.current = null;
          hasReasoningRef.current = false;
          if (currentThreadIdRef.current === threadId) setIsRunning(false);
          if (isLatestRun()) {
            activeRunsRef.current.delete(threadId);
            bridge.current.setRunCallbacks(threadId, null);
          }
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = [
              ...threadMsgs,
              {
                id: `error-${Date.now()}`,
                role: "assistant" as const,
                content: [{ type: "text" as const, text: `⚠ Error: ${errMsg}` }],
              },
            ];
            if (!isServerMode.current) saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
      });

      sendFn();
    },
    [inputId] // eslint-disable-line react-hooks/exhaustive-deps
  );

  // ── onNew ────────────────────────────────────────────────────────────────
  const onNew = useCallback(
    async (msg: AppendMessage) => {
      // 气泡显示用原始文本（含 /commandName chip 序列化结果）
      const text = msg.content
        .filter((c): c is { type: "text"; text: string } => c.type === "text")
        .map((c) => c.text)
        .join("");

      const slashAction = matchSlashAction(text, actionItems);
      if (slashAction) {
        invokeActionRef.current?.(slashAction);
        return;
      }

      // 发给 R 的文本：把 /commandName → cmd.prompt 展开
      // （chip directiveText = "/commandName"，R 需要收到实际 prompt）
      const sendText = expandSlashCommands(text, commands);

      const threadId = currentThreadId;

      // 第一条消息自动命名线程（在任何 updater 外直接读当前 state）
      const isFirstMsg = (messagesMap[threadId] ?? []).length === 0;
      if (isFirstMsg && !manualTitleIds.current.has(threadId)) {
        const title = text.slice(0, 20) + (text.length > 20 ? "…" : "");
        setThreads((ts) => {
          const next = ts.map((t) => (t.id === threadId ? { ...t, title } : t));
          saveThreads(inputId, next);
          return next;
        });
      }

      // 提取附件：序列化为结构化数据供 R 端使用
      const { attachmentData, storedAttachments } = extractAttachments(msg);

      // 追加用户消息
      setCurrentMessages((prev) => [
        ...prev,
        {
          id: `user-${Date.now()}`,
          role: "user" as const,
          content: [{ type: "text" as const, text }],
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          ...(storedAttachments.length > 0 && { attachments: storedAttachments } as any),
        },
      ]);

      startRun(threadId, () => bridge.current.sendUserMessage(
        sendText, threadId,
        attachmentData.length > 0 ? attachmentData : undefined,
      ));
    },
    [inputId, currentThreadId, setCurrentMessages, messagesMap, commands, actionItems, startRun]
  );

  // ── 消息队列:文本-only 投递(队列 flush 用)+ 入队 ─────────────────────────────
  // deliverText 追加用户气泡到指定线程并 startRun 发送(无附件)。存入 ref 供 onDone
  // flush 调用(避免 startRun 闭包对后定义函数的时序依赖)。
  const deliverText = useCallback((text: string, threadId: string) => {
    if (!text.trim()) return;
    const slashAction = matchSlashAction(text, actionItems);
    if (slashAction) {
      invokeActionRef.current?.(slashAction);
      return;
    }
    const sendText = expandSlashCommands(text, commands);
    setMessagesMap((prev) => {
      const threadMsgs = prev[threadId] ?? [];
      const updated: ThreadMessageLike[] = [
        ...threadMsgs,
        { id: `user-${Date.now()}`, role: "user" as const, content: [{ type: "text" as const, text }] },
      ];
      if (!isServerMode.current) saveMessages(inputId, threadId, updated);
      return { ...prev, [threadId]: updated };
    });
    startRun(threadId, () => bridge.current.sendUserMessage(sendText, threadId));
  }, [inputId, commands, actionItems, startRun]);
  deliverTextRef.current = deliverText;

  // 入队:AI 运行中时把消息排队,当前 run 结束后自动发送(见 onDone flush)。
  const enqueueMessage = useCallback((text: string) => {
    if (!text.trim()) return;
    const tid = currentThreadIdRef.current;
    const q = messageQueueRef.current.get(tid) ?? [];
    q.push(text);
    messageQueueRef.current.set(tid, q);
  }, []);

  // ── invokeAction:客户端动作(如 /model /clear),不发给 AI ────────────────────
  // 在对话里记录一条"用户操作"气泡 + 一条系统确认(ack)气泡,并把 action id 发给 R
  // (on_action 执行真实操作,如切模型 / 清历史)。绝不触发 AI run。
  const invokeAction = useCallback((item: ActionItemDef) => {
    const threadId = currentThreadIdRef.current;
    const label = item.label ?? item.id;
    const command = item.command ?? item.id;
    const requestId = makeActionRequestId();
    const ackId = `ack-${requestId}`;
    setMessagesMap((prev) => {
      const msgs = prev[threadId] ?? [];
      const updated: ThreadMessageLike[] = [
        ...msgs,
        { id: `user-${requestId}`, role: "user" as const,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          content: [{ type: "text" as const, text: `/${command}` }], metadata: { custom: { shinyAction: true } } as any },
        { id: ackId, role: "assistant" as const,
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          content: [{ type: "text" as const, text: `\u2699\ufe0f ${label}\u2026` }], metadata: { custom: { shinyActionAck: true } } as any },
      ];
      if (!isServerMode.current) saveMessages(inputId, threadId, updated);
      return { ...prev, [threadId]: updated };
    });
    actionAckRefs.current.set(requestId, { threadId, ackId });
    bridge.current.sendAction(item.id, threadId, { requestId });
  }, [inputId]);
  invokeActionRef.current = invokeAction;

  // ── onEdit ───────────────────────────────────────────────────────────────
  // parentId = 被编辑 user 消息的前一条消息 ID；截断到 parentId，重新插入编辑后的
  // user 消息并重发。必须重新插入——外部存储模式下框架不持有消息，messagesMap 是
  // 唯一真相源，只截断不插入会导致编辑后的 user 气泡从界面消失。
  const onEdit = useCallback(
    async (message: AppendMessage) => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const text = (message.content as any[])
        .filter((p: { type: string }) => p.type === "text")
        .map((p: { text: string }) => p.text)
        .join("");
      if (!text.trim()) return;
      const threadId = currentThreadIdRef.current;
      const parentId = message.parentId ?? null;
      const { attachmentData, storedAttachments } = extractAttachments(message);

      // slash 命令展开（与 onNew 一致）
      const sendText = expandSlashCommands(text, commands);

      // 标志：parentId 陈旧找不到时跳过本次编辑（连 startRun 一起跳过，
      // 避免只发消息给 R 却不插 user 气泡，导致孤儿 assistant 回复 + UI/R 发散）。
      let aborted = false;
      const newUserMessage: ThreadMessageLike = {
        id: `user-${Date.now()}`,
        role: "user" as const,
        content: [{ type: "text" as const, text }],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ...(storedAttachments.length > 0 && { attachments: storedAttachments } as any),
      };
      setMessagesMap((prev) => {
        const threadMsgs = prev[threadId] ?? [];
        const { updated, aborted: ab } = applyEdit(threadMsgs, parentId, newUserMessage);
        if (ab) { aborted = true; return prev; }
        if (!isServerMode.current) saveMessages(inputId, threadId, updated);
        return { ...prev, [threadId]: updated };
      });
      if (aborted) return; // 不发消息给 R，保持 UI/R 一致
      startRun(threadId, () => bridge.current.sendUserMessage(
        sendText, threadId,
        attachmentData.length > 0 ? attachmentData : undefined,
      ));
    },
    [inputId, startRun, commands] // eslint-disable-line react-hooks/exhaustive-deps
  );

  // ── onReload ─────────────────────────────────────────────────────────────  // parentId = 触发本次 assistant 回复的 user 消息 ID
  const onReload = useCallback(
    async (parentId: string | null, _config: StartRunConfig) => {
      const threadId = currentThreadId;
      const msgs = messagesMap[threadId] ?? [];

      // 找到 parent user 消息的文本
      const parentMsg = parentId ? msgs.find((m) => m.id === parentId) : null;
      const rawContent = parentMsg?.content;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const contentArr: any[] = Array.isArray(rawContent) ? rawContent : [];
      const userText = contentArr
        .filter((c) => c?.type === "text")
        .map((c) => c.text as string)
        .join("");

      if (!userText) return;

      // 删除 parentId 之后的所有消息（即上一条 assistant 回复）
      setCurrentMessages((prev) => {
        const idx = parentId ? prev.findIndex((m) => m.id === parentId) : -1;
        return idx >= 0 ? prev.slice(0, idx + 1) : prev;
      });

      startRun(threadId, () => bridge.current.sendReload(userText, threadId));
    },
    [currentThreadId, messagesMap, setCurrentMessages, startRun]
  );

  // ── onCancel ─────────────────────────────────────────────────────────────
  const onCancel = useCallback(async () => {
    const threadId = currentThreadId;
    // Do NOT null streamingIdRef here — in-flight chunks that arrive before R
    // detects the cancel would create a new message bubble (second AI avatar).
    // Let onDone null it naturally once the stream is fully closed.
    hasReasoningRef.current = false;
    setIsRunning(false);
    // Do NOT clear callbacks here — R will still send on_tool_result / on_done
    // during drain mode after interrupt. Let onDone clear them naturally.
    bridge.current.sendCancel(threadId);
  }, [currentThreadId]);

  // ── switchToNewThread（也暴露给外部 slash command 用）─────────────────────
  const switchToNewThread = useCallback(() => {
    const newId = makeThreadId();
    thisSessionThreadIds.current.add(newId);
    const newThread: ExternalStoreThreadData<"regular"> = {
      id: newId,
      status: "regular",
      title: "新对话",
    };
    setThreads((prev) => {
      const next = [newThread, ...prev];
      saveThreads(inputId, next);
      return next;
    });
    setCurrentThreadId(newId);
    setIsRunning(false);
    streamingIdRef.current = null;
  }, [inputId]);

  // ── 线程重命名（rename）──────────────────────────────────────────────────────
  // manualTitleIds：被用户手动改过标题的线程,首条消息自动命名时不再覆盖。
  const renameThread = useCallback((threadId: string, newTitle: string) => {
    const title = newTitle.trim();
    if (!title) return;
    manualTitleIds.current.add(threadId);
    setThreads((prev) => {
      if (!prev.some((t) => t.id === threadId)) return prev;
      const next = prev.map((t) => (t.id === threadId ? { ...t, title } : t));
      saveThreads(inputId, next);
      return next;
    });
    setArchivedThreads((prev) => {
      if (!prev.some((t) => t.id === threadId)) return prev;
      const next = prev.map((t) => (t.id === threadId ? { ...t, title } : t));
      saveArchivedThreads(inputId, next);
      return next;
    });
    bridge.current.sendRename(threadId, title);
  }, [inputId]);

  // ── threadList adapter ───────────────────────────────────────────────────
  const threadListAdapter = useMemo(
    () => ({
      threadId: currentThreadId,
      threads,
      archivedThreads,
      onSwitchToNewThread: switchToNewThread,
      onSwitchToThread: (threadId: string) => {
        setCurrentThreadId(threadId);
        setIsRunning(false);
        streamingIdRef.current = null;
        // 注意：不在切换线程时清空 callbacks——正在运行的流应继续完成
        // 若目标线程是未加载的历史 session，触发懒加载
        if (unloadedSessionIds.current.has(threadId)) {
          bridge.current.sendLoadSession(threadId, threadId);
          unloadedSessionIds.current.delete(threadId);
        }
      },
      onArchive: (threadId: string) => {
        setThreads((prev) => {
          const target = prev.find((t) => t.id === threadId);
          const next = prev.filter((t) => t.id !== threadId);
          saveThreads(inputId, next);
          if (target) {
            setArchivedThreads((arch) => {
              const nextArch = [
                { ...target, status: "archived" as const },
                ...arch,
              ];
              saveArchivedThreads(inputId, nextArch);
              return nextArch;
            });
          }
          if (threadId === currentThreadId) {
            switchAwayFrom(threadId, prev);
          }
          return next;
        });
      },
      onDelete: (threadId: string) => {
        // 从活跃或归档列表中删除
        setThreads((prev) => {
          const inActive = prev.some((t) => t.id === threadId);
          if (!inActive) return prev;
          const next = prev.filter((t) => t.id !== threadId);
          saveThreads(inputId, next);
          deleteMessages(inputId, threadId);
          if (threadId === currentThreadId) {
            switchAwayFrom(threadId, prev);
          }
          return next;
        });
        setArchivedThreads((prev) => {
          const inArchived = prev.some((t) => t.id === threadId);
          if (!inArchived) return prev;
          const next = prev.filter((t) => t.id !== threadId);
          saveArchivedThreads(inputId, next);
          deleteMessages(inputId, threadId);
          return next;
        });
      },
    }),
    [inputId, currentThreadId, threads, archivedThreads, switchAwayFrom]
  );

  const sendToolApproval = useCallback(
    (toolCallId: string, approved: boolean, opts?: { suggestionIdx?: number; customMessage?: string }) => {
      bridge.current.sendToolApproval(toolCallId, approved, opts);
    },
    [] // eslint-disable-line react-hooks/exhaustive-deps
  );

  const setPermissionMode = useCallback((nextValue: string) => {
    if (!permissionCapability || !AVAILABLE_PERMISSION_MODES.has(nextValue)) return;
    const threadId = currentThreadIdRef.current;
    const option = permissionCapability.options.find((item) => item.value === nextValue);
    if (!option || option.disabled) return;

    const requestId = makeActionRequestId();
    const pending = { requestId, requested: nextValue };
    permissionPendingRef.current = {
      ...permissionPendingRef.current,
      [threadId]: pending,
    };
    permissionRequestsRef.current.set(requestId, { threadId, requested: nextValue });
    setPermissionPending(permissionPendingRef.current);
    setPermissionErrors((prev) => ({ ...prev, [threadId]: null }));
    bridge.current.sendAction(`permissions:${nextValue}`, threadId, {
      requestId,
      silent: true,
    });
  }, [permissionCapability]);

  const currentPermissionPending = permissionPending[currentThreadId];
  const permissionMode: PermissionModeState | undefined = permissionCapability
    ? {
        value: currentPermissionPending?.requested
          ?? permissionValues[currentThreadId]
          ?? permissionCapability.value,
        options: permissionCapability.options,
        pending: Boolean(currentPermissionPending),
        error: permissionErrors[currentThreadId] ?? null,
        setValue: setPermissionMode,
      }
    : undefined;

  const runtime = useExternalStoreRuntime({
    messages,
    isRunning,
    suggestions,
    onNew,
    onEdit,
    onReload,
    onCancel,
    convertMessage: (m) => m,
    adapters: {
      threadList: threadListAdapter,
      attachments: attachmentAdapter.current,
      dictation: WebSpeechDictationAdapter.isSupported() ? new WebSpeechDictationAdapter() : undefined,
      speech: (typeof window !== "undefined" && "speechSynthesis" in window) ? new WebSpeechSynthesisAdapter() : undefined,
      feedback: feedbackAdapter.current,
    },
  });

  return {
    runtime, sendToolApproval, switchToNewThread, renameThread, enqueueMessage,
    invokeAction, permissionMode,
    artifacts, activeArtifactId,
    openArtifact: (id: string) => setActiveArtifactId(id),
    closeArtifact: () => setActiveArtifactId(null),
    // ── ClaudeAgentSDK 能力对齐(当前线程视图)────────────────────────────────
    usage: usageMap[currentThreadId],                                    // #1
    tasks: Object.values(tasksMap[currentThreadId] ?? {}),               // #2
    rateLimit,                                                           // #3
    statusText,                                                          // #4
    serverCommands,                                                      // #5
    warming: warmingThreads.has(currentThreadId),                        // 每线程冷启动
    stopTask: (taskId: string) => invokeAction({ id: `stoptask:${taskId}`, label: `Stop task` }), // #7
    forkThread: () => invokeAction({ id: "fork", label: "Fork conversation" }),                    // #6
  };
}
