import React from "react";
import { AssistantRuntimeProvider } from "@assistant-ui/core/react";
import { Thread, ThreadList } from "@assistant-ui/react-ui";
import "@assistant-ui/react-ui/styles/index.css";
import { useShinyRuntime } from "./runtime";

interface AssistantUIProps {
  inputId: string;
  config: Record<string, unknown>;
}

export default function AssistantUI({ inputId, config }: AssistantUIProps) {
  const runtime = useShinyRuntime(inputId, config);
  const showThreadList = config?.show_thread_list === true;

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <div style={{ display: "flex", height: "100%" }}>
        {showThreadList && (
          <div style={{
            width: 220,
            borderRight: "1px solid #e5e7eb",
            overflow: "auto",
            flexShrink: 0,
          }}>
            <ThreadList />
          </div>
        )}
        <div style={{
          flex: 1,
          minWidth: 0,
          "--aui-thread-max-width": "9999px",
        } as React.CSSProperties}>
          <Thread />
        </div>
      </div>
    </AssistantRuntimeProvider>
  );
}
