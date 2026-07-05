import { useEffect, forwardRef, type ReactNode } from "react";
import { AssistantRuntimeProvider, AssistantModalPrimitive } from "@assistant-ui/react";
import { BotIcon } from "lucide-react";
import { Thread } from "@/components/assistant-ui/thread";
import { ThreadList } from "@/components/assistant-ui/thread-list";
import { useShinyRuntime } from "./runtime";
import { ShinyToolFallback } from "./shiny-tool-fallback";
import { ArtifactPanel } from "./artifact-panel";
import { registerApprovalHandler, unregisterApprovalHandler } from "./approval-registry";
import { ShinyConfigContext } from "./shiny-config-context";

interface AssistantUIProps {
  inputId: string;
  config: Record<string, unknown>;
}

const ModalButton = forwardRef<HTMLButtonElement, { "data-state"?: "open" | "closed" }>(
  (props, ref) => (
    <button
      {...props}
      ref={ref}
      className="bg-primary text-primary-foreground flex size-11 items-center justify-center rounded-full shadow-lg"
      aria-label="Open chat"
    >
      <BotIcon className="size-5" />
    </button>
  ),
);
ModalButton.displayName = "ModalButton";

export default function AssistantUI({ inputId, config }: AssistantUIProps) {
  const rt = useShinyRuntime(inputId, config);

  useEffect(() => {
    registerApprovalHandler(inputId, rt.sendToolApproval);
    return () => unregisterApprovalHandler(inputId);
  }, [inputId, rt.sendToolApproval]);

  const activeArtifact = rt.artifacts.find((a) => a.id === rt.activeArtifactId) ?? null;
  const showThreadList = config?.show_thread_list === true;
  const isModal = config?.modal === true;

  const cfgValue = {
    tools: (config?.tools as { name: string; description?: string }[]) ?? [],
    commands: (config?.commands as { name: string; description?: string; prompt: string }[]) ?? [],
    showTimestamps: config?.show_timestamps === true,
    onEnqueue: rt.enqueueMessage,
    onRename: rt.renameThread,
  };

  const threadEl = (
    <Thread
      components={{
        ToolFallback: ShinyToolFallback,
        ToolGroup: ({ children }: { children?: ReactNode }) => (
          <div className="aui-tool-group flex flex-col gap-2">{children}</div>
        ),
      }}
    />
  );

  if (isModal) {
    return (
      <AssistantRuntimeProvider runtime={rt.runtime}>
        <ShinyConfigContext.Provider value={cfgValue}>
          <AssistantModalPrimitive.Root>
            <AssistantModalPrimitive.Anchor className="aui-root aui-modal-anchor fixed end-4 bottom-4 size-11">
              <AssistantModalPrimitive.Trigger asChild>
                <ModalButton />
              </AssistantModalPrimitive.Trigger>
            </AssistantModalPrimitive.Anchor>
            <AssistantModalPrimitive.Content
              sideOffset={16}
              className="aui-root bg-popover text-popover-foreground z-50 h-[500px] w-[400px] overflow-clip rounded-xl border p-0 shadow-md outline-none"
            >
              <div className="flex h-full flex-col">{threadEl}</div>
            </AssistantModalPrimitive.Content>
          </AssistantModalPrimitive.Root>
        </ShinyConfigContext.Provider>
      </AssistantRuntimeProvider>
    );
  }

  return (
    <AssistantRuntimeProvider runtime={rt.runtime}>
      <ShinyConfigContext.Provider value={cfgValue}>
        <div className="aui-root flex h-full min-h-0">
          {showThreadList && (
            <div className="aui-thread-list-sidebar w-56 shrink-0 overflow-y-auto border-r p-2">
              <ThreadList />
            </div>
          )}
          <div className="min-w-0 flex-1">{threadEl}</div>
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
