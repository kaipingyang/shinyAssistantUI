import { AssistantRuntimeProvider } from "@assistant-ui/react";
import { Thread } from "@/components/assistant-ui/thread";
import { useShinyRuntime } from "./runtime";

interface AssistantUIProps {
  inputId: string;
  config: Record<string, unknown>;
}

// Registry-migration root (milestone 4, minimal): official vendored Thread
// driven by the Shiny-backed ExternalStore runtime. Shiny-specific layers
// (approval UI, message queue, artifacts panel, slash/mention, scoped theme)
// are ported incrementally on top — see AssistantUI.legacy.tsx for reference.
export default function AssistantUI({ inputId, config }: AssistantUIProps) {
  const { runtime } = useShinyRuntime(inputId, config);
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <div className="aui-root" style={{ height: "100%", minHeight: 0 }}>
        <Thread />
      </div>
    </AssistantRuntimeProvider>
  );
}
