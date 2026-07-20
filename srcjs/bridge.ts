// Shiny ↔ React 通信桥
// 封装 Shiny.setInputValue 和 addCustomMessageHandler

declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export type AttachmentData = {
  type: string;        // "image" | "text" | "file"
  name: string;
  data: string;        // data URL for images, text content for text, base64 for files
  contentType?: string;
};


export type IdeContextPolicy = { selectionVisible: boolean };
export type IdeContextMeta = {
  requestId?: string;
  threadId?: string;
  activeFile?: string;
  relativePath?: string;
  startLine?: number;
  endLine?: number;
  hasSelection?: boolean;
  selectionChars?: number;
  selectionVisible?: boolean;
  documentVersion?: string | number;
};
export type WorkspaceMentionItem = {
  kind: "file" | "folder";
  path: string;
  label?: string;
  insertText?: string;
};
export type WorkspaceResults = {
  requestId?: string;
  threadId?: string;
  items: WorkspaceMentionItem[];
};

export type ToolCallPayload = {
  toolCallId: string;
  toolName: string;
  args: Record<string, unknown>;
  argsText: string;
  annotations?: Record<string, unknown>;
};

export type SessionItem = {
  id: string;
  title: string;
  preview: string;
  createdAt: string; // ISO 8601 datetime string
};

export type RunCallbacks = {
  onChunk: (text: string) => void;
  onThinking?: (text: string) => void;
  onToolCall: (toolCall: ToolCallPayload) => void;
  onToolCallStart?: (toolCallId: string, toolName: string, annotations?: Record<string, unknown>) => void;
  onToolCallDelta?: (toolCallId: string, delta: string) => void;
  onToolResult: (toolCallId: string, result: unknown, isError: boolean) => void;
  onSource?: (source: { url: string; title?: string; id?: string }) => void;
  onImage?: (image: string) => void;
  onArtifact?: (artifact: { id: string; title: string; type: string; content: string; lang?: string }) => void;
  onDone: (suggestions?: Array<{prompt: string}>) => void;
  onError: (message: string) => void;
};

export type ActionRequestOptions = {
  requestId?: string;
  silent?: boolean;
};

export type ActionResult = {
  threadId?: string;
  requestId?: string;
  actionId?: string;
  message?: string;
  status?: string;
  value?: unknown;
};

export interface ShinyBridge {
  sendUserMessage: (text: string, threadId: string, attachments?: AttachmentData[], ideContext?: IdeContextPolicy) => void;
  sendReload: (text: string, threadId: string) => void;
  sendCancel: (threadId: string) => void;
  sendToolApproval: (toolCallId: string, approved: boolean, opts?: { suggestionIdx?: number; customMessage?: string }) => void;
  sendAction: (actionId: string, threadId: string, options?: ActionRequestOptions) => void;
  sendRename: (threadId: string, title: string) => void;
  sendLoadSession: (sessionId: string, threadId: string) => void;
  sendFeedback: (messageId: string, type: "positive" | "negative") => void;
  sendReady: () => void;
  sendWarmup: (threadId: string) => void;
  requestIdeContext: (requestId: string, threadId: string) => void;
  searchWorkspace: (requestId: string, threadId: string, query: string, kinds?: Array<"file" | "folder">, limit?: number) => void;
  setRunCallbacks: (threadId: string, callbacks: RunCallbacks | null) => void;
  onClear: (handler: () => void) => void;
  onActionResult: (handler: (data: ActionResult) => void) => void;
  onSessions: (handler: (data: { sessions: SessionItem[] }) => void) => void;
  onLoadThread: (handler: (data: { threadId: string; messages: unknown[] }) => void) => void;
  onUsage: (handler: (data: { threadId?: string; costUsd?: number; tokens?: number; turns?: number; durationMs?: number; model?: string }) => void) => void;
  onTask: (handler: (data: { threadId?: string; taskId: string; kind: string; description?: string; status?: string; toolName?: string; summary?: string }) => void) => void;
  onRateLimit: (handler: (data: { threadId?: string; status?: string; resetsAt?: string; utilization?: number; type?: string }) => void) => void;
  onStatus: (handler: (data: { threadId?: string; status: string; text?: string }) => void) => void;
  onWarming: (handler: (data: { threadId?: string; active?: boolean }) => void) => void;
  onServerCommands: (handler: (data: { threadId?: string; commands?: unknown[]; outputStyles?: unknown[] }) => void) => void;
  onIdeContext: (handler: (data: IdeContextMeta) => void) => void;
  onWorkspaceResults: (handler: (data: WorkspaceResults) => void) => void;
}

export function createShinyBridge(inputId: string): ShinyBridge {
  // 按 threadId 存储 callbacks，支持多 thread 并发（切 thread 不丢失旧 handler 回调）
  const callbacksMap = new Map<string, RunCallbacks>();
  let sessionsHandler: ((data: { sessions: SessionItem[] }) => void) | null = null;
  let loadThreadHandler: ((data: { threadId: string; messages: unknown[] }) => void) | null = null;
  // `:sessions` 可能在 useEffect 注册 handler 前到达（Shiny 首次 flush 早于 React paint）
  // 缓冲最后一条，onSessions() 注册时立即回放
  let bufferedSessions: { sessions: SessionItem[] } | null = null;

  // 按 threadId 取回调。缺 threadId 时：单线程场景回退到唯一回调；多线程则告警 + 放弃
  // （静默路由到"第一个"会在并发时投递到错误线程）。R 端所有消息都应带 threadId。
  const routeCallback = (threadId?: string): RunCallbacks | undefined => {
    if (threadId) return callbacksMap.get(threadId);
    if (callbacksMap.size === 1) return callbacksMap.values().next().value;
    if (callbacksMap.size > 1) {
      console.warn("[shinyAssistantUI] message without threadId dropped (multiple active threads)");
    }
    return undefined;
  };

  // 注册一次，内部路由到对应 threadId 的回调
  Shiny.addCustomMessageHandler(`${inputId}:chunk`, (data) => {
    const d = data as { text: string; threadId?: string };
    routeCallback(d.threadId)?.onChunk(d.text);
  });

  Shiny.addCustomMessageHandler(`${inputId}:done`, (data) => {
    const d = data as { suggestions?: Array<{prompt: string}>; threadId?: string };
    routeCallback(d.threadId)?.onDone(d.suggestions);
  });

  Shiny.addCustomMessageHandler(`${inputId}:error`, (data) => {
    const d = data as { message: string; threadId?: string };
    routeCallback(d.threadId)?.onError(d.message);
  });

  Shiny.addCustomMessageHandler(`${inputId}:thinking`, (data) => {
    const d = data as { text: string; threadId?: string };
    routeCallback(d.threadId)?.onThinking?.(d.text);
  });

  Shiny.addCustomMessageHandler(`${inputId}:source`, (data) => {
    const d = data as { url: string; title?: string; id?: string; threadId?: string };
    routeCallback(d.threadId)?.onSource?.({ url: d.url, title: d.title, id: d.id });
  });

  Shiny.addCustomMessageHandler(`${inputId}:image`, (data) => {
    const d = data as { image: string; threadId?: string };
    routeCallback(d.threadId)?.onImage?.(d.image);
  });

  Shiny.addCustomMessageHandler(`${inputId}:artifact`, (data) => {
    const d = data as { id: string; title: string; type: string; content: string; lang?: string; threadId?: string };
    routeCallback(d.threadId)?.onArtifact?.({ id: d.id, title: d.title, type: d.type, content: d.content, lang: d.lang });
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-call`, (data) => {
    const d = data as ToolCallPayload & { threadId?: string };
    routeCallback(d.threadId)?.onToolCall(d);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-call-start`, (data) => {
    const d = data as { toolCallId: string; toolName: string; annotations?: Record<string, unknown>; threadId?: string };
    routeCallback(d.threadId)?.onToolCallStart?.(d.toolCallId, d.toolName, d.annotations);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-call-delta`, (data) => {
    const d = data as { toolCallId: string; delta: string; threadId?: string };
    routeCallback(d.threadId)?.onToolCallDelta?.(d.toolCallId, d.delta);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-result`, (data) => {
    const d = data as { toolCallId: string; result: unknown; isError?: boolean; threadId?: string };
    routeCallback(d.threadId)?.onToolResult(d.toolCallId, d.result, d.isError ?? false);
  });

  Shiny.addCustomMessageHandler(`${inputId}:sessions`, (data) => {
    const d = data as { sessions: SessionItem[] };
    if (sessionsHandler) {
      sessionsHandler(d);
    } else {
      bufferedSessions = d; // 缓冲，等 onSessions() 注册后回放
    }
  });

  Shiny.addCustomMessageHandler(`${inputId}:load-thread`, (data) => {
    loadThreadHandler?.(data as { threadId: string; messages: unknown[] });
  });

  return {
    sendUserMessage(text, threadId, attachments, ideContext) {
      Shiny.setInputValue(
        inputId,
        { text, threadId, attachments: attachments ?? [], ...(ideContext && { ideContext }), ts: Date.now() },
        { priority: "event" }
      );
    },

    sendReload(text, threadId) {
      Shiny.setInputValue(
        inputId,
        { type: "reload", text, threadId, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendCancel(threadId) {
      Shiny.setInputValue(
        `${inputId}_cancel`,
        { threadId, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendToolApproval(toolCallId, approved, opts) {
      Shiny.setInputValue(
        `${inputId}_tool_approval`,
        { toolCallId, approved, suggestionIdx: opts?.suggestionIdx ?? null, customMessage: opts?.customMessage ?? null, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendAction(actionId, threadId, options = {}) {
      Shiny.setInputValue(
        `${inputId}_action`,
        {
          id: actionId,
          threadId,
          requestId: options.requestId,
          silent: options.silent ?? false,
          ts: Date.now(),
        },
        { priority: "event" }
      );
    },

    sendRename(threadId, title) {
      Shiny.setInputValue(
        `${inputId}_rename`,
        { threadId, title, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendLoadSession(sessionId, threadId) {
      Shiny.setInputValue(
        inputId,
        { type: "load_session", sessionId, threadId, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendFeedback(messageId, type) {
      Shiny.setInputValue(
        `${inputId}_feedback`,
        { messageId, type, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendReady() {
      Shiny.setInputValue(
        `${inputId}_sessions_ready`,
        { ts: Date.now() },
        { priority: "event" }
      );
    },
    sendWarmup(threadId) {
      Shiny.setInputValue(
        `${inputId}_warmup`,
        { threadId, ts: Date.now() },
        { priority: "event" }
      );
    },

    requestIdeContext(requestId, threadId) {
      Shiny.setInputValue(
        `${inputId}_ide_context_refresh`,
        { requestId, threadId, ts: Date.now() },
        { priority: "event" },
      );
    },

    searchWorkspace(requestId, threadId, query, kinds = ["file", "folder"], limit = 50) {
      Shiny.setInputValue(
        `${inputId}_workspace_search`,
        { requestId, threadId, query, kinds, limit, ts: Date.now() },
        { priority: "event" },
      );
    },

    setRunCallbacks(threadId, callbacks) {
      if (callbacks === null) {
        callbacksMap.delete(threadId);
      } else {
        callbacksMap.set(threadId, callbacks);
      }
    },

    onClear(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:clear`, (_data) => handler());
    },

    onActionResult(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:action-result`, (data) => {
        handler(data as ActionResult);
      });
    },

    onUsage(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:usage`, (data) => handler(data as never));
    },
    onTask(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:task`, (data) => handler(data as never));
    },
    onRateLimit(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:rate-limit`, (data) => handler(data as never));
    },
    onStatus(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:status`, (data) => handler(data as never));
    },
    onWarming(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:warming`, (data) => handler(data as never));
    },
    onServerCommands(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:server-commands`, (data) => handler(data as never));
    },
    onIdeContext(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:ide-context`, (data) => handler(data as IdeContextMeta));
    },
    onWorkspaceResults(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:workspace-results`, (data) => handler(data as WorkspaceResults));
    },

    onSessions(handler) {
      sessionsHandler = handler;
      if (bufferedSessions) {       // 回放缓冲的 :sessions 消息
        handler(bufferedSessions);
        bufferedSessions = null;
      }
    },

    onLoadThread(handler) {
      loadThreadHandler = handler;
    },
  };
}
