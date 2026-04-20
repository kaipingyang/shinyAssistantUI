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

export type RunCallbacks = {
  onChunk: (text: string) => void;
  onToolCall: (toolCall: ToolCallPayload) => void;
  onToolResult: (toolCallId: string, result: unknown, isError: boolean) => void;
  onDone: () => void;
  onError: (message: string) => void;
};

export interface ShinyBridge {
  sendUserMessage: (text: string, threadId: string, attachments?: AttachmentData[]) => void;
  sendReload: (text: string, threadId: string) => void;
  sendCancel: (threadId: string) => void;
  setRunCallbacks: (callbacks: RunCallbacks | null) => void;
  onClear: (handler: () => void) => void;
}

export function createShinyBridge(inputId: string): ShinyBridge {
  let currentCallbacks: RunCallbacks | null = null;

  // 注册一次，内部路由到当前运行的回调
  Shiny.addCustomMessageHandler(`${inputId}:chunk`, (data) => {
    const d = data as { text: string };
    currentCallbacks?.onChunk(d.text);
  });

  Shiny.addCustomMessageHandler(`${inputId}:done`, (_data) => {
    currentCallbacks?.onDone();
  });

  Shiny.addCustomMessageHandler(`${inputId}:error`, (data) => {
    const d = data as { message: string };
    currentCallbacks?.onError(d.message);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-call`, (data) => {
    currentCallbacks?.onToolCall(data as ToolCallPayload);
  });

  Shiny.addCustomMessageHandler(`${inputId}:tool-result`, (data) => {
    const d = data as { toolCallId: string; result: unknown; isError?: boolean };
    currentCallbacks?.onToolResult(d.toolCallId, d.result, d.isError ?? false);
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

    setRunCallbacks(callbacks) {
      currentCallbacks = callbacks;
    },

    onClear(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:clear`, (_data) => handler());
    },
  };
}
