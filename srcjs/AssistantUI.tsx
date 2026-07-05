import { useEffect, type ReactNode } from "react";
import { AssistantRuntimeProvider } from "@assistant-ui/react";
import { Thread } from "@/components/assistant-ui/thread";
import { useShinyRuntime } from "./runtime";
import { ShinyToolFallback } from "./shiny-tool-fallback";
import { ArtifactPanel } from "./artifact-panel";
import { registerApprovalHandler, unregisterApprovalHandler } from "./approval-registry";
import { ShinyConfigContext } from "./shiny-config-context";

interface AssistantUIProps {
  inputId: string;
  config: Record<string, unknown>;
}

// Registry-migration root: official vendored Thread (markdown / reasoning / sources /
// image / tool-group / attachments / voice / branch / action-bar all official) +
// Shiny-backed ExternalStore runtime + Shiny tool approval + artifacts side panel.
export default function AssistantUI({ inputId, config }: AssistantUIProps) {
  const rt = useShinyRuntime(inputId, config);

  // 注册本 widget 的审批 handler(供 ShinyToolFallback 的 approval 按钮路由到 R)
  useEffect(() => {
    registerApprovalHandler(inputId, rt.sendToolApproval);
    return () => unregisterApprovalHandler(inputId);
  }, [inputId, rt.sendToolApproval]);

  const activeArtifact =
    rt.artifacts.find((a) => a.id === rt.activeArtifactId) ?? null;

  const cfgValue = {
    tools: (config?.tools as { name: string; description?: string }[]) ?? [],
    commands: (config?.commands as { name: string; description?: string; prompt: string }[]) ?? [],
    showTimestamps: config?.show_timestamps === true,
    onEnqueue: rt.enqueueMessage,
  };

  return (
    <AssistantRuntimeProvider runtime={rt.runtime}>
      <ShinyConfigContext.Provider value={cfgValue}>
      <div className="aui-root flex h-full min-h-0">
        <div className="min-w-0 flex-1">
          <Thread
            components={{
              ToolFallback: ShinyToolFallback,
              // 展开渲染工具调用(不折叠成 "N tool calls"),使审批按钮/结果直接可见
              ToolGroup: ({ children }: { children?: ReactNode }) => (
                <div className="aui-tool-group flex flex-col gap-2">{children}</div>
              ),
            }}
          />
        </div>
        {activeArtifact && (
          <div className="w-[45%] min-w-[320px] shrink-0">
            <ArtifactPanel artifact={activeArtifact} onClose={rt.closeArtifact} />
          </div>
        )}
      </div>
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}
