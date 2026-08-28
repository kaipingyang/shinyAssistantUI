import { useEffect, forwardRef, lazy, Suspense, type ReactNode } from "react";
import { AssistantRuntimeProvider, AssistantModalPrimitive } from "@assistant-ui/react";

// Build-time flag (vite define, default false). When false, the devtools dynamic import below
// is dead-code and tree-shaken OUT of the prod bundle. Build with `AUI_DEVTOOLS=1 npm run build`
// to include it for debugging (then enable at runtime via ?aui-devtools=1 or config.devtools).
declare const __AUI_DEVTOOLS__: boolean;
const DevToolsModalLazy = __AUI_DEVTOOLS__
  ? lazy(() =>
      import("@assistant-ui/react-devtools").then((m) => ({ default: m.DevToolsModal })),
    )
  : null;
import { BotIcon } from "lucide-react";
import { Thread } from "@/components/assistant-ui/thread";
import { ThreadList } from "@/components/assistant-ui/thread-list";
import { ThreadSidebar, SidebarToggleButton, useSidebarCollapse } from "@/components/assistant-ui/thread-sidebar";
import { SidebarSettings } from "@/components/assistant-ui/settings-controls";
import { WorkingDirBar } from "@/components/assistant-ui/working-dir-bar";
import { useShinyRuntime } from "./runtime";
import { mergeSlashCommands } from "./helpers";
import { ShinyToolFallback } from "./shiny-tool-fallback";
import { ArtifactPanel } from "./artifact-panel";
import { registerApprovalHandler, unregisterApprovalHandler } from "./approval-registry";
import { ShinyConfigContext } from "./shiny-config-context";

// Dev-only(默认关):在浏览器加 `?aui-devtools=1`(或 config.devtools=TRUE)时,挂载官方
// @assistant-ui/react-devtools 的浮层 modal,便于迁移期检查 ExternalStore 运行时/消息 parts。
// 必须在 AssistantRuntimeProvider 内渲染。默认不启用,不影响正常使用。
function ShinyDevTools({ config }: { config: Record<string, unknown> }) {
  if (!__AUI_DEVTOOLS__ || !DevToolsModalLazy) return null;
  const enabled =
    config?.devtools === true ||
    (typeof window !== "undefined" &&
      new URLSearchParams(window.location.search).has("aui-devtools"));
  if (!enabled) return null;
  return (
    <Suspense fallback={null}>
      <DevToolsModalLazy />
    </Suspense>
  );
}

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

  // Plan 34 (fix): 当 LaTeX 开启,mount 时主动预载 KaTeX 字体(本地 woff2,~170KB),
  // 使字体在公式绘制前就绪 → 消除"忽大忽小"重排(尤其打开历史一次渲染多条公式时)。
  // fire-and-forget:document.fonts.load 触发浏览器立即取字体,不阻塞渲染。
  useEffect(() => {
    if (config?.latex !== true) return;
    const fonts = (document as Document & { fonts?: FontFaceSet }).fonts;
    if (!fonts?.load) return;
    const families = [
      "KaTeX_Main", "KaTeX_Math", "KaTeX_Size1", "KaTeX_Size2", "KaTeX_Size3",
      "KaTeX_Size4", "KaTeX_AMS", "KaTeX_Caligraphic", "KaTeX_Fraktur",
      "KaTeX_SansSerif", "KaTeX_Script", "KaTeX_Typewriter",
    ];
    for (const f of families) {
      for (const style of ["", "italic ", "bold "]) {
        try { void fonts.load(`${style}16px "${f}"`); } catch { /* ignore */ }
      }
    }
  }, [config?.latex]);

  const activeArtifact = rt.artifacts.find((a) => a.id === rt.activeArtifactId) ?? null;
  const showThreadList = config?.show_thread_list === true;
  const isModal = config?.modal === true;
  // 侧栏默认展开：用户经常需要从历史列表里选会话，打开就该看得到。
  // 折叠只在本会话有效、不持久化（不传 storageKey），因此每次重开 addin 都回到展开态；
  // 本次会话内仍可临时收起腾出空间。
  const sidebar = useSidebarCollapse();

  const configuredCommands = (config?.commands as {
    name: string; description?: string; prompt: string; category?: string;
    source?: string; kind?: string;
  }[]) ?? [];
  const actionItems = (config?.action_items as {
    section?: string; id: string; command?: string; label?: string; description?: string;
  }[]) ?? [];
  const cfgValue = {
    tools: (config?.tools as { name: string; description?: string }[]) ?? [],
    commands: mergeSlashCommands(rt.commands ?? configuredCommands, rt.serverCommands, actionItems),
    actionItems,
    showTimestamps: config?.show_timestamps === true,
    workspaceMode: rt.workspaceMode,
    onEnqueue: rt.enqueueMessage,
    submissionRevision: rt.submissionRevision,
    onRename: rt.renameThread,
    onInvokeAction: rt.invokeAction,
    onOpenFile: rt.openFile,
    onRunInConsole: rt.consoleRunEnabled ? rt.runInConsole : undefined,
    blockingAction: rt.blockingAction,
    permissionMode: rt.permissionMode,
    thinking: rt.thinking,
    model: rt.model,
    ideContext: rt.ideContext,
    selectionVisible: rt.selectionVisible,
    setSelectionVisible: rt.setSelectionVisible,
    refreshIdeContext: rt.refreshIdeContext,
    workspaceMentions: rt.workspaceMentions,
    searchWorkspace: rt.searchWorkspace,
    lazyToolResults: rt.lazyToolResults,
    readingHistory: rt.readingHistory,
    historyHasMore: rt.historyHasMore,
    loadingOlder: rt.loadingOlder,
    loadOlderHistory: rt.loadOlderHistory,
    usage: rt.usage,
    agentState: rt.agentState,
    latex: config?.latex === true,
    showUsage: config?.show_usage === true,
    contextWindow: typeof config?.context_window === "number" ? config.context_window : undefined,
    usageStyle: (config?.usage_style as "ring" | "bar" | "text" | undefined) ?? "ring",
    tasks: rt.tasks,
    recentTasks: rt.recentTasks,
    checklist: rt.checklist,
    dismissChecklist: rt.dismissChecklist,
    rateLimit: rt.rateLimit,
    statusText: rt.statusText,
    serviceState: rt.serviceState,
    pendingServiceSubmissions: rt.pendingServiceSubmissions,
    retryService: rt.retryService,
    cancelPendingServiceSubmissions: rt.cancelPendingSubmissions,
    warming: rt.warming,
    warmingResuming: rt.warmingResuming,
    runPhase: rt.runPhase,
    runStage: rt.runStage,
    runQueuePosition: rt.runQueuePosition,
    cancelRun: rt.cancelRun,
    warmingLabel: config?.warming_label as string | undefined,
    welcomeMessage: config?.welcome_message as string | undefined,
    stopTask: rt.stopTask,
    forkThread: rt.forkThread,
    // 折叠时主面板左上角浮着展开按钮 → 让"当前提问"框左侧留白，二者并排不重叠
    sidebarCollapsed: showThreadList && sidebar.collapsed,
    // 工作目录选择器（addin）
    workingDir: rt.workingDir,
    gitBranch: rt.gitBranch,
    recentDirs: rt.recentDirs,
    nativePicker: rt.nativePicker,
    pickWorkingDir: rt.pickWorkingDir,
    setWorkingDir: rt.setWorkingDir,
    projects: rt.projects,
    workspaceProjectOrder: rt.workspaceProjectOrder,
    newThreadInProject: rt.newThreadInProject,
    saveProject: rt.saveProject,
    removeProject: rt.removeProject,
    filesPaneFollow: rt.filesPaneFollow,
    setFilesPaneFollow: rt.setFilesPaneFollow,
    autoRunEnabled: rt.autoRunEnabled,
    setAutoRunEnabled: rt.setAutoRunEnabled,
    defaultPermissionMode: rt.defaultPermissionMode,
    setDefaultPermissionMode: rt.setDefaultPermissionMode,
    modeVisibility: rt.modeVisibility,
    setModeVisibility: rt.setModeVisibility,
    composerDensity: rt.composerDensity,
    setComposerDensity: rt.setComposerDensity,
    assistantTextSize: rt.assistantTextSize,
    setAssistantTextSize: rt.setAssistantTextSize,
    runREnabled: rt.runREnabled,
    setRunREnabled: rt.setRunREnabled,
    autoStartCopilotApi: rt.autoStartCopilotApi,
    setAutoStartCopilotApi: rt.setAutoStartCopilotApi,
    threadMaxWidth: rt.threadMaxWidth,
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
          <ShinyDevTools config={config ?? {}} />
        </ShinyConfigContext.Provider>
      </AssistantRuntimeProvider>
    );
  }

  return (
    <AssistantRuntimeProvider runtime={rt.runtime}>
      <ShinyConfigContext.Provider value={cfgValue}>
        <div className="aui-root flex h-full min-h-0">
          {showThreadList && (
            <ThreadSidebar collapsed={sidebar.collapsed} onToggle={sidebar.toggle}>
              <WorkingDirBar />
              <div className="min-h-0 flex-1">
                <ThreadList />
              </div>
              <SidebarSettings />
            </ThreadSidebar>
          )}
          <div className="relative min-h-0 min-w-0 flex-1">
            {showThreadList && sidebar.collapsed && (
              <SidebarToggleButton
                collapsed
                onToggle={sidebar.toggle}
                className="bg-background/80 absolute start-2 top-2 z-30 border shadow-sm backdrop-blur"
              />
            )}
            {threadEl}
          </div>
          {activeArtifact && (
            <div className="w-[45%] min-w-[320px] shrink-0">
              <ArtifactPanel artifact={activeArtifact} onClose={rt.closeArtifact} />
            </div>
          )}
        </div>
        <ShinyDevTools config={config ?? {}} />
      </ShinyConfigContext.Provider>
    </AssistantRuntimeProvider>
  );
}
