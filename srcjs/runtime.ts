// useShinyRuntime — ExternalStoreRuntime + 多线程 + localStorage 持久化
import { useRef, useCallback, useState, useEffect, useMemo } from "react";
import { useExternalStoreRuntime } from "@assistant-ui/react";
import type {
  ThreadMessageLike,
  AppendMessage,
  ExternalStoreThreadData,
} from "@assistant-ui/core";
import { createShinyBridge } from "./bridge";
import type { ShinyBridge } from "./bridge";

// ── 持久化 key ──────────────────────────────────────────────────────────────

function storageKey(inputId: string, suffix: string) {
  return `shinyAssistantUI:${inputId}:${suffix}`;
}

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
  } catch {}
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
  } catch {}
}

function loadMessages(inputId: string, threadId: string): ThreadMessageLike[] {
  try {
    const raw = localStorage.getItem(storageKey(inputId, `msgs:${threadId}`));
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

function saveMessages(inputId: string, threadId: string, msgs: ThreadMessageLike[]) {
  try {
    localStorage.setItem(storageKey(inputId, `msgs:${threadId}`), JSON.stringify(msgs));
  } catch {}
}

function deleteMessages(inputId: string, threadId: string) {
  try {
    localStorage.removeItem(storageKey(inputId, `msgs:${threadId}`));
  } catch {}
}

function makeThreadId() {
  return `t_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

// ── hook ────────────────────────────────────────────────────────────────────

type CommandDef = { name: string; description: string; prompt: string };

export function useShinyRuntime(inputId: string, config: Record<string, unknown>) {
  // 从 config 提取 commands，用于 /commandName → cmd.prompt 展开（useMemo 稳定引用）
  const commands = useMemo(
    () => (config?.commands as CommandDef[] | undefined) ?? [],
    [config],
  );
  // 懒初始化：避免每次 render 都调用 createShinyBridge（会重复注册 Shiny handler
  // 覆盖旧的，但 useRef 还是返回第一个 bridge，导致 handler 和 callbacks 对应的闭包不一致）
  const bridge = useRef<ShinyBridge>(null!);
  if (!bridge.current) {
    bridge.current = createShinyBridge(inputId);
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
    return saved.length > 0 ? saved[0].id : makeThreadId();
  });

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
  const streamingIdRef = useRef<string | null>(null);

  // 当前线程消息
  const messages = useMemo(
    () => messagesMap[currentThreadId] ?? [],
    [messagesMap, currentThreadId]
  );

  // 更新消息并持久化
  const setCurrentMessages = useCallback(
    (updater: (prev: ThreadMessageLike[]) => ThreadMessageLike[]) => {
      setMessagesMap((prev) => {
        const updated = updater(prev[currentThreadId] ?? []);
        saveMessages(inputId, currentThreadId, updated);
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
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ── onNew ────────────────────────────────────────────────────────────────
  const onNew = useCallback(
    async (msg: AppendMessage) => {
      // 气泡显示用原始文本（含 /commandName chip 序列化结果）
      const text = msg.content
        .filter((c): c is { type: "text"; text: string } => c.type === "text")
        .map((c) => c.text)
        .join("");

      // 发给 R 的文本：把 /commandName → cmd.prompt 展开
      // （chip directiveText = "/commandName"，R 需要收到实际 prompt）
      let sendText = text;
      for (const cmd of commands) {
        if (sendText.includes(`/${cmd.name}`)) {
          sendText = sendText.split(`/${cmd.name}`).join(cmd.prompt);
        }
      }

      const threadId = currentThreadId;

      // 第一条消息自动命名线程（在任何 updater 外直接读当前 state）
      const isFirstMsg = (messagesMap[threadId] ?? []).length === 0;
      if (isFirstMsg) {
        const title = text.slice(0, 20) + (text.length > 20 ? "…" : "");
        setThreads((ts) => {
          const next = ts.map((t) => (t.id === threadId ? { ...t, title } : t));
          saveThreads(inputId, next);
          return next;
        });
      }

      // 追加用户消息
      setCurrentMessages((prev) => [
        ...prev,
        {
          id: `user-${Date.now()}`,
          role: "user" as const,
          content: [{ type: "text" as const, text }],
        },
      ]);

      setIsRunning(true);

      // 注册本次运行回调（push → state）
      bridge.current.setRunCallbacks({
        onChunk: (chunkText) => {
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            let updated: ThreadMessageLike[];
            if (!streamingIdRef.current) {
              const id = `assistant-${Date.now()}`;
              streamingIdRef.current = id;
              updated = [
                ...threadMsgs,
                { id, role: "assistant", content: [{ type: "text", text: chunkText }] },
              ];
            } else {
              updated = threadMsgs.map((m) => {
                if (m.id !== streamingIdRef.current) return m;
                const prev2 = m.content[0]?.type === "text" ? m.content[0].text : "";
                return { ...m, content: [{ type: "text", text: prev2 + chunkText }] };
              });
            }
            saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onToolCall: (toolCall) => {
          // 每个 tool call 作为独立的 assistant 消息插入
          streamingIdRef.current = null; // 中断当前文本流（如有）
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated: ThreadMessageLike[] = [
              ...threadMsgs,
              {
                id: `tool-${toolCall.toolCallId}`,
                role: "assistant" as const,
                content: [
                  {
                    type: "tool-call" as const,
                    toolCallId: toolCall.toolCallId,
                    toolName: toolCall.toolName,
                    args: toolCall.args,
                    argsText: toolCall.argsText,
                    artifact: toolCall.annotations,
                  },
                ],
              },
            ];
            saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onToolResult: (toolCallId, result, isError) => {
          setMessagesMap((prev) => {
            const threadMsgs = prev[threadId] ?? [];
            const updated = threadMsgs.map((m) => {
              const part = m.content[0];
              if (part?.type !== "tool-call") return m;
              if ((part as { toolCallId?: string }).toolCallId !== toolCallId) return m;
              return {
                ...m,
                content: [{ ...part, result, isError }],
              };
            });
            saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
        onDone: () => {
          streamingIdRef.current = null;
          setIsRunning(false);
          bridge.current.setRunCallbacks(null);
        },
        onError: (errMsg) => {
          streamingIdRef.current = null;
          setIsRunning(false);
          bridge.current.setRunCallbacks(null);
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
            saveMessages(inputId, threadId, updated);
            return { ...prev, [threadId]: updated };
          });
        },
      });

      bridge.current.sendUserMessage(sendText, threadId);
    },
    [inputId, currentThreadId, setCurrentMessages, messagesMap, commands]
  );

  // ── threadList adapter ───────────────────────────────────────────────────
  const threadListAdapter = useMemo(
    () => ({
      threadId: currentThreadId,
      threads,
      archivedThreads,
      onSwitchToNewThread: () => {
        const newId = makeThreadId();
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
        // 注意：不在切换线程时清空 callbacks——正在运行的流应继续完成
      },
      onSwitchToThread: (threadId: string) => {
        setCurrentThreadId(threadId);
        setIsRunning(false);
        streamingIdRef.current = null;
        // 注意：不在切换线程时清空 callbacks——正在运行的流应继续完成
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

  return useExternalStoreRuntime({
    messages,
    isRunning,
    onNew,
    convertMessage: (m) => m,
    adapters: {
      threadList: threadListAdapter,
    },
  });
}
