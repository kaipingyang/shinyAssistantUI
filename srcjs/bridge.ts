// Shiny ↔ React 通信桥
// 封装 Shiny.setInputValue 和 addCustomMessageHandler

declare const Shiny: {
  setInputValue: (id: string, value: unknown, opts?: { priority?: string }) => void;
  addCustomMessageHandler: (type: string, handler: (data: unknown) => void) => void;
};

export type ChunkHandler = (text: string) => void;
export type DoneHandler = () => void;
export type ErrorHandler = (message: string) => void;

export interface ShinyBridge {
  sendUserMessage: (text: string, attachments?: string[]) => void;
  onChunk: (handler: ChunkHandler) => void;
  onDone: (handler: DoneHandler) => void;
  onError: (handler: ErrorHandler) => void;
  onNewMessage: (handler: DoneHandler) => void;
  onClear: (handler: DoneHandler) => void;
}

export function createShinyBridge(inputId: string): ShinyBridge {
  return {
    sendUserMessage(text, attachments = []) {
      Shiny.setInputValue(inputId, { text, attachments, ts: Date.now() }, { priority: "event" });
    },
    onChunk(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:chunk`, (data) => {
        const d = data as { text: string };
        handler(d.text);
      });
    },
    onDone(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:done`, (_data) => handler());
    },
    onError(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:error`, (data) => {
        const d = data as { message: string };
        handler(d.message);
      });
    },
    onNewMessage(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:new_message`, (_data) => handler());
    },
    onClear(handler) {
      Shiny.addCustomMessageHandler(`${inputId}:clear`, (_data) => handler());
    },
  };
}
