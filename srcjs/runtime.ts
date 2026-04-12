// useShinyRuntime — ExternalStoreRuntime + 多线程 + localStorage 持久化
import { useRef, useCallback, useState, useEffect, useMemo } from "react";
import { useExternalStoreRuntime } from "@assistant-ui/react";
import type {
  ThreadMessageLike,
  AppendMessage,
  ExternalStoreThreadData,
} from "@assistant-ui/core";
import { createShinyBridge } from "./bridge";

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

function makeThreadId() {
  return `t_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;
}

// ── hook ────────────────────────────────────────────────────────────────────

export function useShinyRuntime(inputId: string, config: Record<string, unknown>) {
  const bridge = useRef(createShinyBridge(inputId));

  // 线程列表（持久化）
  const [threads, setThreads] = useState<ExternalStoreThreadData<"regular">[]>(() =>
    loadThreads(inputId)
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
      const text = msg.content
        .filter((c): c is { type: "text"; text: string } => c.type === "text")
        .map((c) => c.text)
        .join("");

      const threadId = currentThreadId;

      // 追加用户消息
      setCurrentMessages((prev) => {
        const updated = [
          ...prev,
          {
            id: `user-${Date.now()}`,
            role: "user" as const,
            content: [{ type: "text" as const, text }],
          },
        ];
        // 第一条消息自动命名线程
        if (prev.length === 0) {
          const title = text.slice(0, 20) + (text.length > 20 ? "…" : "");
          setThreads((ts) => {
            const next = ts.map((t) => (t.id === threadId ? { ...t, title } : t));
            saveThreads(inputId, next);
            return next;
          });
        }
        return updated;
      });

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

      bridge.current.sendUserMessage(text, threadId);
    },
    [inputId, currentThreadId, setCurrentMessages]
  );

  // ── threadList adapter ───────────────────────────────────────────────────
  const threadListAdapter = useMemo(
    () => ({
      threadId: currentThreadId,
      threads,
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
        bridge.current.setRunCallbacks(null);
      },
      onSwitchToThread: (threadId: string) => {
        setCurrentThreadId(threadId);
        setIsRunning(false);
        streamingIdRef.current = null;
        bridge.current.setRunCallbacks(null);
      },
    }),
    [inputId, currentThreadId, threads]
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
