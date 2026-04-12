// Shiny ↔ React 通信桥
// 封装 Shiny.setInputValue 和 addCustomMessageHandler

declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export type RunCallbacks = {
  onChunk: (text: string) => void;
  onDone: () => void;
  onError: (message: string) => void;
};

export interface ShinyBridge {
  sendUserMessage: (text: string, threadId: string, attachments?: string[]) => void;
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

  return {
    sendUserMessage(text, threadId, attachments = []) {
      Shiny.setInputValue(
        inputId,
        { text, threadId, attachments, ts: Date.now() },
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
