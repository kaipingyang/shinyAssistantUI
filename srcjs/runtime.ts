// useShinyRuntime — 将 Shiny 消息流适配为 @assistant-ui/react 的 ExternalStoreRuntime
import { useRef, useCallback, useState } from "react";
import { useExternalStoreRuntime } from "@assistant-ui/react";
import type { ThreadMessageLike, AppendMessage } from "@assistant-ui/core";
import { createShinyBridge } from "./bridge";

export function useShinyRuntime(inputId: string) {
  const bridge = useRef(createShinyBridge(inputId));
  const [messages, setMessages] = useState<ThreadMessageLike[]>([]);
  const [isRunning, setIsRunning] = useState(false);
  const streamingIdRef = useRef<string | null>(null);

  // Register Shiny handlers once on mount
  const bridgeRegistered = useRef(false);
  if (!bridgeRegistered.current) {
    bridgeRegistered.current = true;

    bridge.current.onChunk((text) => {
      setMessages((prev) => {
        if (!streamingIdRef.current) {
          const id = `assistant-${Date.now()}`;
          streamingIdRef.current = id;
          return [
            ...prev,
            { id, role: "assistant", content: [{ type: "text", text }] },
          ];
        }
        return prev.map((m) => {
          if (m.id !== streamingIdRef.current) return m;
          const prevText =
            m.content[0]?.type === "text" ? m.content[0].text : "";
          return {
            ...m,
            content: [{ type: "text", text: prevText + text }],
          };
        });
      });
    });

    bridge.current.onDone(() => {
      streamingIdRef.current = null;
      setIsRunning(false);
    });

    bridge.current.onError((message) => {
      streamingIdRef.current = null;
      setIsRunning(false);
      setMessages((prev) => [
        ...prev,
        {
          id: `error-${Date.now()}`,
          role: "assistant",
          content: [{ type: "text", text: `⚠ Error: ${message}` }],
        },
      ]);
    });

    bridge.current.onClear(() => {
      streamingIdRef.current = null;
      setIsRunning(false);
      setMessages([]);
    });
  }

  const onNew = useCallback(async (msg: AppendMessage) => {
    const text = msg.content
      .filter((c): c is { type: "text"; text: string } => c.type === "text")
      .map((c) => c.text)
      .join("");

    setMessages((prev) => [
      ...prev,
      { id: `user-${Date.now()}`, role: "user", content: [{ type: "text", text }] },
    ]);
    setIsRunning(true);

    bridge.current.sendUserMessage(text);
  }, []);

  return useExternalStoreRuntime({
    messages,
    isRunning,
    onNew,
    // convertMessage is required when messages is ThreadMessageLike[].
    // It routes each message through fromThreadMessageLike internally,
    // so metadata / status fields are properly initialized (no undefined.submittedFeedback).
    convertMessage: (m) => m,
  });
}
