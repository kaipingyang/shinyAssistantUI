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
  onToolResult: (toolCallId: string, result: unknown, isError: boolean) => void;
  onDone: (suggestions?: Array<{prompt: string}>) => void;
  onError: (message: string) => void;
};

export interface ShinyBridge {
  sendUserMessage: (text: string, threadId: string, attachments?: AttachmentData[]) => void;
  sendReload: (text: string, threadId: string) => void;
  sendCancel: (threadId: string) => void;
  sendToolApproval: (toolCallId: string, approved: boolean) => void;
  sendAction: (actionId: string) => void;
  sendLoadSession: (sessionId: string, threadId: string) => void;
  sendFeedback: (messageId: string, type: "positive" | "negative") => void;
  sendReady: () => void;
  setRunCallbacks: (callbacks: RunCallbacks | null) => void;
  onClear: (handler: () => void) => void;
  onSessions: (handler: (data: { sessions: SessionItem[] }) => void) => void;
  onLoadThread: (handler: (data: { threadId: string; messages: unknown[] }) => void) => void;
}

export function createShinyBridge(inputId: string): ShinyBridge {
  let currentCallbacks: RunCallbacks | null = null;
  let sessionsHandler: ((data: { sessions: SessionItem[] }) => void) | null = null;
  let loadThreadHandler: ((data: { threadId: string; messages: unknown[] }) => void) | null = null;
  // `:sessions` 可能在 useEffect 注册 handler 前到达（Shiny 首次 flush 早于 React paint）
  // 缓冲最后一条，onSessions() 注册时立即回放
  let bufferedSessions: { sessions: SessionItem[] } | null = null;

  // 注册一次，内部路由到当前运行的回调
  Shiny.addCustomMessageHandler(`${inputId}:chunk`, (data) => {
    const d = data as { text: string };
    currentCallbacks?.onChunk(d.text);
  });

  Shiny.addCustomMessageHandler(`${inputId}:done`, (data) => {
    const d = data as { suggestions?: Array<{prompt: string}> };
    currentCallbacks?.onDone(d.suggestions);
  });

  Shiny.addCustomMessageHandler(`${inputId}:error`, (data) => {
    const d = data as { message: string };
    currentCallbacks?.onError(d.message);
  });

  Shiny.addCustomMessageHandler(`${inputId}:thinking`, (data) => {
    const d = data as { text: string };
    currentCallbacks?.onThinking?.(d.text);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-call`, (data) => {
    currentCallbacks?.onToolCall(data as ToolCallPayload);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-result`, (data) => {
    const d = data as { toolCallId: string; result: unknown; isError?: boolean };
    currentCallbacks?.onToolResult(d.toolCallId, d.result, d.isError ?? false);
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
    sendUserMessage(text, threadId, attachments) {
      Shiny.setInputValue(
        inputId,
        { text, threadId, attachments: attachments ?? [], ts: Date.now() },
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

    sendToolApproval(toolCallId, approved) {
      Shiny.setInputValue(
        `${inputId}_tool_approval`,
        { toolCallId, approved, ts: Date.now() },
        { priority: "event" }
      );
    },

    sendAction(actionId) {
      Shiny.setInputValue(
        `${inputId}_action`,
        { id: actionId, ts: Date.now() },
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

    setRunCallbacks(callbacks) {
      currentCallbacks = callbacks;
    },

    onClear(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:clear`, (_data) => handler());
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
