import { useEffect, forwardRef, type ReactNode } from "react";
import { AssistantRuntimeProvider, AssistantModalPrimitive } from "@assistant-ui/react";
import { BotIcon } from "lucide-react";
import { Thread } from "@/components/assistant-ui/thread";
import { ThreadList } from "@/components/assistant-ui/thread-list";
import { SidebarSettings } from "@/components/assistant-ui/settings-controls";
import { useShinyRuntime } from "./runtime";
import { mergeSlashCommands } from "./helpers";
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

  const configuredCommands = (config?.commands as {
    name: string; description?: string; prompt: string; category?: string;
    source?: string; kind?: string;
  }[]) ?? [];
  const actionItems = (config?.action_items as {
    section?: string; id: string; command?: string; label?: string; description?: string;
  }[]) ?? [];
  const cfgValue = {
    tools: (config?.tools as { name: string; description?: string }[]) ?? [],
    commands: mergeSlashCommands(configuredCommands, rt.serverCommands, actionItems),
    actionItems,
    showTimestamps: config?.show_timestamps === true,
    onEnqueue: rt.enqueueMessage,
    onRename: rt.renameThread,
    onInvokeAction: rt.invokeAction,
    permissionMode: rt.permissionMode,
    usage: rt.usage,
    tasks: rt.tasks,
    rateLimit: rt.rateLimit,
    statusText: rt.statusText,
    warming: rt.warming,
    stopTask: rt.stopTask,
    forkThread: rt.forkThread,
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
            <div className="aui-thread-list-sidebar relative flex w-56 shrink-0 flex-col overflow-hidden border-r p-2">
              <div className="min-h-0 flex-1 overflow-y-auto">
                <ThreadList />
              </div>
              <SidebarSettings />
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
