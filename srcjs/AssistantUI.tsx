import React from "react";
import { AssistantRuntimeProvider } from "@assistant-ui/core/react";
import { Thread } from "@assistant-ui/react-ui";
import "@assistant-ui/react-ui/styles/index.css";
import { useShinyRuntime } from "./runtime";

interface AssistantUIProps {
  inputId: string;
}

export default function AssistantUI({ inputId }: AssistantUIProps) {
  const runtime = useShinyRuntime(inputId);

  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <div style={{ height: "100%", "--aui-thread-max-width": "9999px" } as React.CSSProperties}>
        <Thread />
      </div>
    </AssistantRuntimeProvider>
  );
}
