"use client";
import { safeUrl as shinySafeUrl } from "@/helpers";
import { useShinyConfig } from "@/shiny-config-context";
import { formatMessageTime } from "@/helpers";

import {
  ComposerAddAttachment,
  ComposerAttachments,
  UserMessageAttachments,
} from "@/components/assistant-ui/attachment";
import { MarkdownText } from "@/components/assistant-ui/markdown-text";
import {
  Reasoning,
  ReasoningContent,
  ReasoningRoot,
  ReasoningText,
  ReasoningTrigger,
} from "@/components/assistant-ui/reasoning";
import { ShinyComposerInput } from "@/components/assistant-ui/composer-input";
import { ShinyCurrentQuestion, useAllUserQuestions } from "@/components/assistant-ui/current-question";
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { renderToolPart } from "@/tool-ui/registry";
import { PermissionModeControl, ModelPickerDialog } from "@/components/assistant-ui/settings-controls";
import { ShinyContextDisplay } from "@/components/assistant-ui/context-display";
import { ShinyAgentProgress } from "@/hooks/use-agent-state";
import {
  ToolGroupContent,
  ToolGroupRoot,
  ToolGroupTrigger,
} from "@/components/assistant-ui/tool-group";
import { TooltipIconButton } from "@/components/assistant-ui/tooltip-icon-button";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import {
  ActionBarMorePrimitive,
  ActionBarPrimitive,
  AuiIf,
  type AssistantState,
  BranchPickerPrimitive,
  ComposerPrimitive,
  ErrorPrimitive,
  groupPartByType,
  MessagePrimitive,
  SuggestionPrimitive,
  ThreadPrimitive,
  type ToolCallMessagePartComponent,
  useAuiState,
  useAui,
} from "@assistant-ui/react";
import {
  ArrowDownIcon,
  ArrowUpIcon,
  CheckIcon,
  ChevronLeftIcon,
  ChevronRightIcon,
  CopyIcon,
  DownloadIcon,
  EyeIcon,
  EyeOffIcon,
  FileTextIcon,
  MicIcon,
  ClockIcon,
  MoreHorizontalIcon,
  PencilIcon,
  RefreshCwIcon,
  SquareIcon,
} from "lucide-react";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentType,
  type FC,
  type PropsWithChildren,
} from "react";

export type ThreadGroupPart = MessagePrimitive.GroupedParts.GroupPart;

/**
 * Optional component overrides for the thread. `AssistantMessage` and
 * `Welcome` replace whole sections; the remaining slots override how the
 * assistant message renders tool calls and part groups. Tool UIs registered
 * by name (toolkit `render`, `useAssistantDataUI`) take precedence over
 * `ToolFallback`.
 */
export type ThreadComponents = {
  AssistantMessage?: ComponentType | undefined;
  Welcome?: ComponentType | undefined;
  ToolFallback?: ToolCallMessagePartComponent | undefined;
  ToolGroup?:
    | ComponentType<PropsWithChildren<{ group: ThreadGroupPart }>>
    | undefined;
  ReasoningGroup?:
    | ComponentType<PropsWithChildren<{ group: ThreadGroupPart }>>
    | undefined;
};

export type ThreadProps = {
  components?: ThreadComponents | undefined;
};

const EMPTY_COMPONENTS: ThreadComponents = {};

const ThreadComponentsContext =
  createContext<ThreadComponents>(EMPTY_COMPONENTS);

// Startup exposes a loading placeholder thread; treat it as a new chat so
// the composer mounts centered. Loads after startup keep the docked layout.
const isNewChatView = (s: AssistantState) =>
  s.thread.messages.length === 0 &&
  (!s.thread.isLoading || s.threads.isLoading);

export const Thread: FC<ThreadProps> = ({ components = EMPTY_COMPONENTS }) => {
  const isEmpty = useAuiState(isNewChatView);

  return (
    <ThreadComponentsContext.Provider value={components}>
      <ThreadRoot isEmpty={isEmpty} />
    </ThreadComponentsContext.Provider>
  );
};

const ThreadRoot: FC<{ isEmpty: boolean }> = ({ isEmpty }) => {
  const { Welcome = ThreadWelcome } = useContext(ThreadComponentsContext);
  const { historyHasMore, loadingOlder, loadOlderHistory, threadMaxWidth, composerDensity } = useShinyConfig();
  const viewportRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const olderAnchorRef = useRef<{ height: number; top: number } | null>(null);
  const previousLoadingOlderRef = useRef(Boolean(loadingOlder));
  // 内容溢出（需翻页）时才显示顶部"当前提问"小框，短对话不占布局。
  const [overflowing, setOverflowing] = useState(false);

  // scroll-spy：顶部条显示【当前视口所在那一轮】的用户提问(而非恒定最新)。
  const questionsJoined = useAllUserQuestions();
  const questions = useMemo(
    () => (questionsJoined ? questionsJoined.split("\u0000") : []),
    [questionsJoined],
  );
  const [activeIdx, setActiveIdx] = useState(-1);
  const computeActiveQuestion = useCallback(() => {
    const vp = viewportRef.current;
    if (!vp) return;
    const threshold = vp.getBoundingClientRect().top + 40; // 避让 sticky 条高度
    const users = vp.querySelectorAll('[data-role="user"]');
    let idx = -1;
    users.forEach((el, i) => {
      if (el.getBoundingClientRect().top <= threshold) idx = i;
    });
    setActiveIdx(idx);
  }, []);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport || typeof ResizeObserver === "undefined") return;
    const measure = () => {
      setOverflowing(viewport.scrollHeight > viewport.clientHeight + 24);
      computeActiveQuestion();
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(viewport);
    if (contentRef.current) observer.observe(contentRef.current);
    return () => observer.disconnect();
  }, [computeActiveQuestion]);

  // 消息数/溢出态变化(新提问、翻页加载、流式)时重算当前轮。
  useEffect(() => {
    computeActiveQuestion();
  }, [questionsJoined, overflowing, computeActiveQuestion]);

  // 原生 scroll 监听:任何滚动(用户滚轮/拖动、程序化 scrollTop、内容 settle)都重算当前轮
  // —— 比 React onScroll 更可靠(程序化滚动也触发)。
  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return;
    viewport.addEventListener("scroll", computeActiveQuestion, { passive: true });
    return () => viewport.removeEventListener("scroll", computeActiveQuestion);
  }, [computeActiveQuestion]);

  const activeQuestion =
    activeIdx >= 0 && activeIdx < questions.length
      ? questions[activeIdx]
      : (questions[questions.length - 1] ?? "");

  const requestOlder = () => {
    if (!historyHasMore || loadingOlder || !loadOlderHistory) return;
    const viewport = viewportRef.current;
    if (viewport) {
      olderAnchorRef.current = {
        height: viewport.scrollHeight,
        top: viewport.scrollTop,
      };
    }
    loadOlderHistory();
  };

  useLayoutEffect(() => {
    const wasLoading = previousLoadingOlderRef.current;
    previousLoadingOlderRef.current = Boolean(loadingOlder);
    if (!wasLoading || loadingOlder || !olderAnchorRef.current) return;
    const viewport = viewportRef.current;
    if (viewport) {
      const anchor = olderAnchorRef.current;
      viewport.scrollTop = anchor.top + (viewport.scrollHeight - anchor.height);
    }
    olderAnchorRef.current = null;
  }, [loadingOlder]);

  return (
    <ThreadPrimitive.Root
      className="aui-root aui-thread-root bg-background @container flex h-full flex-col"
      style={{
        ["--thread-max-width" as string]: threadMaxWidth || "none",
        ["--composer-bg" as string]:
          "color-mix(in oklab, var(--color-muted) 30%, var(--color-background))",
        ["--composer-radius" as string]: "1.5rem",
        // Plan 45:输入框高度两档。compact = 更扁(更矮的起始输入 + 更小内边距,≈shinychat),
        // comfortable = 现状。只改起始/内边距;自动增高(max-h-32)不变。
        ["--composer-padding" as string]: composerDensity === "compact" ? "4px" : "8px",
        ["--composer-min-height" as string]: composerDensity === "compact" ? "1.5rem" : "2.5rem",
      }}
    >
      <ThreadPrimitive.Viewport
        ref={viewportRef}
        data-slot="aui_thread-viewport"
        onScroll={(event) => {
          if (event.currentTarget.scrollTop <= 120) requestOlder();
        }}
        className="relative flex min-h-0 flex-1 flex-col overflow-x-auto overflow-y-scroll scroll-smooth"
      >
        <ShinyCurrentQuestion visible={overflowing} question={activeQuestion} />
        <div
          ref={contentRef}
          className={cn(
            "mx-auto flex w-full max-w-(--thread-max-width) flex-1 flex-col px-4 pt-4",
            isEmpty && "justify-center",
          )}
        >
          <AuiIf condition={isNewChatView}>
            <Welcome />
          </AuiIf>

          <div
            data-slot="aui_message-group"
            className="mb-14 flex flex-col gap-y-6 empty:hidden"
          >
            <ShinyHistoryControls onLoadOlder={requestOlder} />
            <ThreadPrimitive.Messages>
              {() => <ThreadMessage />}
            </ThreadPrimitive.Messages>
            <ShinyWarmingIndicator />
          </div>

          <ThreadPrimitive.ViewportFooter
            className={cn(
              "aui-thread-viewport-footer bg-background flex flex-col gap-4 overflow-visible pb-4 md:pb-6",
              !isEmpty &&
                "sticky bottom-0 mt-auto rounded-t-(--composer-radius)",
            )}
          >
            <ThreadScrollToBottom />
            <ShinyStatusPanels />
            <Composer />
            <ShinyUsageFooter />
            <AuiIf condition={(s) => isNewChatView(s) && s.composer.isEmpty}>
              <ThreadSuggestions />
            </AuiIf>
          </ThreadPrimitive.ViewportFooter>
        </div>
      </ThreadPrimitive.Viewport>
    </ThreadPrimitive.Root>
  );
};

const ShinyHistoryControls: FC<{ onLoadOlder: () => void }> = ({ onLoadOlder }) => {
  const { readingHistory, historyHasMore, loadingOlder } = useShinyConfig();
  if (readingHistory) {
    return (
      <div
        data-slot="aui_history_reading"
        className="text-muted-foreground flex items-center justify-center gap-2 py-3 text-sm"
      >
        <span className="inline-block size-3 animate-spin rounded-full border-2 border-primary border-t-transparent" />
        <span>Loading history…</span>
      </div>
    );
  }
  if (!historyHasMore) return null;
  return (
    <div className="flex justify-center">
      <button
        type="button"
        data-slot="aui_load_older"
        disabled={loadingOlder}
        onClick={onLoadOlder}
        className="text-muted-foreground hover:bg-accent rounded-full border px-3 py-1 text-xs disabled:cursor-wait disabled:opacity-60"
      >
        {loadingOlder ? "Loading older messages…" : "Load older messages"}
      </button>
    </div>
  );
};

const ThreadMessage: FC = () => {
  const { AssistantMessage: AssistantMessageComponent = AssistantMessage } =
    useContext(ThreadComponentsContext);
  const role = useAuiState((s) => s.message.role);
  const isEditing = useAuiState((s) => s.message.composer.isEditing);

  if (isEditing) return <EditComposer />;
  if (role === "user") return <UserMessage />;
  return <AssistantMessageComponent />;
};

const ThreadScrollToBottom: FC = () => {
  return (
    <ThreadPrimitive.ScrollToBottom asChild>
      <TooltipIconButton
        tooltip="Scroll to bottom"
        variant="outline"
        className="aui-thread-scroll-to-bottom dark:border-border dark:bg-background dark:hover:bg-accent absolute -top-12 z-10 self-center rounded-full p-4 disabled:invisible"
      >
        <ArrowDownIcon />
      </TooltipIconButton>
    </ThreadPrimitive.ScrollToBottom>
  );
};

const ThreadWelcome: FC = () => {
  return (
    <div className="aui-thread-welcome-root mb-6 flex flex-col items-center px-4 text-center">
      <h1 className="aui-thread-welcome-message-inner fade-in slide-in-from-bottom-1 animate-in fill-mode-both text-2xl font-semibold duration-200">
        How can I help you today?
      </h1>
    </div>
  );
};

const ThreadSuggestions: FC = () => {
  return (
    <div className="aui-thread-welcome-suggestions flex w-full flex-wrap items-center justify-center gap-2 px-4">
      <ThreadPrimitive.Suggestions>
        {() => <ThreadSuggestionItem />}
      </ThreadPrimitive.Suggestions>
    </div>
  );
};

const ThreadSuggestionItem: FC = () => {
  return (
    <div className="aui-thread-welcome-suggestion-display fade-in slide-in-from-bottom-2 animate-in fill-mode-both duration-200">
      <SuggestionPrimitive.Trigger send asChild>
        <Button
          variant="ghost"
          className="aui-thread-welcome-suggestion text-foreground hover:bg-muted border-border/60 h-auto gap-1.5 rounded-full border px-3.5 py-1.5 text-sm font-normal whitespace-nowrap transition-colors"
        >
          <SuggestionPrimitive.Title className="aui-thread-welcome-suggestion-text-1" />
          <SuggestionPrimitive.Description className="aui-thread-welcome-suggestion-text-2 empty:hidden" />
        </Button>
      </SuggestionPrimitive.Trigger>
    </div>
  );
};

const IdeContextIndicator: FC = () => {
  const { ideContext, selectionVisible, setSelectionVisible } = useShinyConfig();
  if (!ideContext?.relativePath && !ideContext?.activeFile) return null;
  const file = ideContext.relativePath ?? ideContext.activeFile;
  const hasLines = ideContext.hasSelection && ideContext.startLine != null;
  const lineText = hasLines
    ? ideContext.endLine && ideContext.endLine !== ideContext.startLine
      ? `lines ${ideContext.startLine}-${ideContext.endLine}`
      : `line ${ideContext.startLine}`
    : null;
  return (
    <div
      data-slot="aui_ide_context"
      data-context-file={file}
      data-selection-visible={selectionVisible ? "true" : "false"}
      className="aui-ide-context text-muted-foreground flex min-w-0 items-center gap-1.5 px-2 text-xs"
    >
      <FileTextIcon className="size-3.5 shrink-0" />
      <span className={cn("truncate", !selectionVisible && "line-through opacity-60")}>{file}</span>
      {lineText && <span className={cn("shrink-0", !selectionVisible && "line-through opacity-60")}>· {lineText}</span>}
      <button
        type="button"
        data-slot="aui_selection_visibility"
        aria-label={selectionVisible ? "Hide this file from Claude" : "Send this file to Claude"}
        title={selectionVisible ? "Hide this file from Claude" : "Send this file to Claude"}
        onClick={() => setSelectionVisible(!selectionVisible)}
        className="hover:bg-accent ml-auto flex shrink-0 items-center gap-1 rounded px-1.5 py-0.5"
      >
        {selectionVisible ? <EyeIcon className="size-3.5" /> : <EyeOffIcon className="size-3.5" />}
        <span>{selectionVisible ? (ideContext.hasSelection ? "Context included" : "File included") : "Hidden"}</span>
      </button>
    </div>
  );
};

const Composer: FC = () => {
  const { refreshIdeContext, composerDensity } = useShinyConfig();
  const compact = composerDensity === "compact";
  return (
    <ComposerPrimitive.Root className="aui-composer-root relative flex w-full flex-col">
      <ShinyAgentProgress />
      <ComposerPrimitive.AttachmentDropzone asChild>
        <div
          data-slot="aui_composer-shell"
          data-density={composerDensity ?? "comfortable"}
          className="border-border/60 data-[dragging=true]:border-ring focus-within:border-border dark:border-muted-foreground/15 dark:focus-within:border-muted-foreground/30 flex w-full flex-col gap-2 rounded-(--composer-radius) border bg-(--composer-bg) p-(--composer-padding) shadow-[0_4px_16px_-8px_rgba(0,0,0,0.08),0_1px_2px_rgba(0,0,0,0.04)] transition-[border-color,box-shadow] focus-within:shadow-[0_6px_24px_-8px_rgba(0,0,0,0.12),0_1px_2px_rgba(0,0,0,0.05)] data-[dragging=true]:border-dashed data-[dragging=true]:bg-[color-mix(in_oklab,var(--color-accent)_50%,var(--color-background))] dark:shadow-none"
        >
          <ComposerAttachments />
          <IdeContextIndicator />
          {compact ? (
            // 扁平单行(≈shinychat):保留全部左侧控件(附件/权限/模型/用量环)+ 输入(flex-1)+ 发送,
            // 全在一行;附件预览 / IDE 上下文条在上方按需出现。comfortable 保留完整两行布局。
            <div className="aui-composer-compact-row flex items-end gap-1.5">
              <ComposerAddAttachment />
              <PermissionModeControl compact />
              <ModelPickerDialog />
              <ShinyContextDisplay />
              <div className="min-w-0 flex-1">
                <ShinyComposerInput onFocus={refreshIdeContext} />
              </div>
              <ComposerSendGroup />
            </div>
          ) : (
            <>
              <ShinyComposerInput onFocus={refreshIdeContext} />
              <ComposerAction />
            </>
          )}
        </div>
      </ComposerPrimitive.AttachmentDropzone>
    </ComposerPrimitive.Root>
  );
};

// Per-thread Claude CLI connection indicator.
const ShinyWarmingIndicator: FC = () => {
  const { warming, warmingResuming } = useShinyConfig();
  if (!warming) return null;
  return (
    <div
      data-slot="aui_warming"
      data-resuming={warmingResuming ? "true" : "false"}
      className="aui-warming-indicator flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm text-muted-foreground"
    >
      <span className="inline-block size-3 shrink-0 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      <span>{warmingResuming ? "Resuming Claude Code session…" : "Starting Claude Code…"}</span>
    </div>
  );
};

const ShinyStatusPanels: FC = () => {
  const { rateLimit, tasks, statusText, stopTask } = useShinyConfig();
  const activeTasks = (tasks ?? []).filter(
    (task) => !/^(completed|done|stopped|failed|cancelled|canceled|errored)$/i.test(task.status ?? ""),
  );
  const hasAny = rateLimit || activeTasks.length > 0 || statusText;
  if (!hasAny) return null;
  return (
    <div className="aui-sdk-panels flex flex-col gap-2">
      {rateLimit && (
        <div
          className="aui-rate-limit-banner flex items-center gap-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-800 dark:border-amber-700 dark:bg-amber-950/40 dark:text-amber-200"
          data-slot="aui_rate_limit"
        >
          <span>⚠️ Rate limited{rateLimit.type ? ` (${rateLimit.type})` : ""}</span>
          {typeof rateLimit.utilization === "number" && <span>· {Math.round(rateLimit.utilization)}% used</span>}
          {rateLimit.resetsAt && <span>· resets {rateLimit.resetsAt}</span>}
        </div>
      )}
      {activeTasks.map((task) => (
        <div
          key={task.taskId}
          data-slot="aui_task_card"
          data-task-id={task.taskId}
          className="aui-task-card flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm"
        >
          <span className="animate-pulse">⚙️</span>
          <span className="flex-1 truncate">
            {task.description || task.summary || `Subagent ${task.taskId.slice(0, 6)}`}
            {task.toolName ? <span className="text-muted-foreground"> · {task.toolName}</span> : null}
            {task.status ? <span className="text-muted-foreground"> · {task.status}</span> : null}
          </span>
          {stopTask && (
            <button
              type="button"
              data-slot="aui_task_stop"
              data-stop-task={task.taskId}
              onClick={() => stopTask(task.taskId)}
              className="rounded px-2 py-0.5 text-xs text-destructive hover:bg-destructive/10"
            >
              Stop
            </button>
          )}
        </div>
      ))}
      {statusText && (
        <div
          className="aui-status-line flex items-center gap-2 px-1 text-xs text-muted-foreground"
          data-slot="aui_status_line"
        >
          <span className="inline-block h-2 w-2 animate-pulse rounded-full bg-primary" />
          <span>{statusText}</span>
        </div>
      )}
    </div>
  );
};

const ShinyUsageFooter: FC = () => {
  const { usage } = useShinyConfig();
  if (!usage || (usage.costUsd == null && usage.tokens == null)) return null;
  const parts: string[] = [];
  if (usage.costUsd != null) parts.push(`$${usage.costUsd.toFixed(4)}`);
  if (usage.tokens != null) parts.push(`${usage.tokens.toLocaleString()} tokens`);
  if (usage.turns != null) parts.push(`${usage.turns} turn${usage.turns === 1 ? "" : "s"}`);
  if (usage.durationMs != null) parts.push(`${(usage.durationMs / 1000).toFixed(1)}s`);
  return (
    <div
      className="aui-usage-footer flex items-center justify-end gap-2 px-1 text-xs text-muted-foreground"
      data-slot="aui_usage_footer"
      data-cost-usd={usage.costUsd ?? ""}
    >
      <span>{parts.join(" · ")}</span>
    </div>
  );
};

const ComposerQueue: FC = () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const aui = useAui() as any;
  const { onEnqueue } = useShinyConfig();
  return (
    <TooltipIconButton
      tooltip="Queue message (send after current reply)"
      side="bottom"
      type="button"
      variant="ghost"
      size="icon"
      className="aui-composer-queue-btn size-7 rounded-full"
      aria-label="Queue message"
      onClick={() => {
        const t = (aui.composer.getState().text as string) ?? "";
        if (t.trim()) {
          onEnqueue(t);
          aui.composer.setText("");
        }
      }}
    >
      <ClockIcon className="size-4" />
    </TooltipIconButton>
  );
};

// 消息时间戳(从 message id 尾部 epoch 解析),gated by config.show_timestamps
const ShinyTimestamp: FC = () => {
  const { showTimestamps } = useShinyConfig();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const id = useAuiState((s: any) => s.message?.id as string | undefined);
  if (!showTimestamps) return null;
  const t = formatMessageTime(id);
  if (!t) return null;
  return (
    <span className="aui-message-timestamp text-muted-foreground px-1 text-[10px]" data-timestamp={t}>
      {t}
    </span>
  );
};

const ComposerSendGroup: FC = () => {
  return (
    <div className="flex items-center gap-1.5">
      <AuiIf condition={(s) => s.thread.capabilities.dictation}>
        <AuiIf condition={(s) => s.composer.dictation == null}>
          <ComposerPrimitive.Dictate asChild>
            <TooltipIconButton
              tooltip="Voice input"
              side="bottom"
              type="button"
              variant="ghost"
              size="icon"
              className="aui-composer-dictate size-7 rounded-full"
              aria-label="Start voice input"
            >
              <MicIcon className="aui-composer-dictate-icon size-4" />
            </TooltipIconButton>
          </ComposerPrimitive.Dictate>
        </AuiIf>
        <AuiIf condition={(s) => s.composer.dictation != null}>
          <ComposerPrimitive.StopDictation asChild>
            <TooltipIconButton
              tooltip="Stop dictation"
              side="bottom"
              type="button"
              variant="ghost"
              size="icon"
              className="aui-composer-stop-dictation text-destructive size-7 rounded-full"
              aria-label="Stop voice input"
            >
              <SquareIcon className="aui-composer-stop-dictation-icon size-3.5 animate-pulse fill-current" />
            </TooltipIconButton>
          </ComposerPrimitive.StopDictation>
        </AuiIf>
      </AuiIf>
      <AuiIf condition={(s) => !s.thread.isRunning}>
        <ComposerPrimitive.Send asChild>
          <TooltipIconButton
            tooltip="Send message"
            side="bottom"
            type="button"
            variant="default"
            size="icon"
            className="aui-composer-send size-7 rounded-full"
            aria-label="Send message"
          >
            <ArrowUpIcon className="aui-composer-send-icon size-4.5" />
          </TooltipIconButton>
        </ComposerPrimitive.Send>
      </AuiIf>
      <AuiIf condition={(s) => s.thread.isRunning}>
        <ComposerQueue />
        <ComposerPrimitive.Cancel asChild>
          <Button
            type="button"
            variant="default"
            size="icon"
            className="aui-composer-cancel size-7 rounded-full"
            aria-label="Stop generating"
          >
            <SquareIcon className="aui-composer-cancel-icon size-3.5 fill-current" />
          </Button>
        </ComposerPrimitive.Cancel>
      </AuiIf>
    </div>
  );
};

const ComposerAction: FC = () => {
  return (
    <div className="aui-composer-action-wrapper relative flex items-center justify-between">
      <div className="flex min-w-0 items-center gap-1.5">
        <ComposerAddAttachment />
        <PermissionModeControl compact />
        <ModelPickerDialog />
        <ShinyContextDisplay />
      </div>
      <ComposerSendGroup />
    </div>
  );
};

const MessageError: FC = () => {
  return (
    <MessagePrimitive.Error>
      <ErrorPrimitive.Root className="aui-message-error-root border-destructive bg-destructive/10 text-destructive dark:bg-destructive/5 mt-2 rounded-md border p-3 text-sm dark:text-red-200">
        <ErrorPrimitive.Message className="aui-message-error-message line-clamp-2" />
      </ErrorPrimitive.Root>
    </MessagePrimitive.Error>
  );
};

const AssistantMessage: FC = () => {
  const {
    ToolFallback: ToolFallbackComponent = ToolFallback,
    ToolGroup,
    ReasoningGroup,
  } = useContext(ThreadComponentsContext);

  // reserves space for action bar and compensates with `-mb` for consistent msg spacing
  // keeps hovered action bar from shifting layout (autohide doesn't support absolute positioning well)
  // for pt-[n] use -mb-[n + 6] & min-h-[n + 6] to preserve compensation
  const ACTION_BAR_PT = "pt-1.5";
  // Keep the action bar inside the contained root's paint box, then cancel its reserved space in flow.
  const ACTION_BAR_HEIGHT = `min-h-7.5 ${ACTION_BAR_PT}`;

  return (
    <MessagePrimitive.Root
      data-slot="aui_assistant-message-root"
      data-role="assistant"
      className="fade-in slide-in-from-bottom-1 animate-in relative -mb-7.5 pb-7.5 duration-150 [contain-intrinsic-size:auto_200px] [content-visibility:auto]"
    >
      <div
        data-slot="aui_assistant-message-content"
        className="text-foreground px-2 leading-relaxed wrap-break-word"
      >
        <MessagePrimitive.GroupedParts
          groupBy={groupPartByType({
            reasoning: ["group-chainOfThought", "group-reasoning"],
            "tool-call": ["group-chainOfThought", "group-tool"],
            "standalone-tool-call": [],
          })}
        >
          {({ part, children }) => {
            switch (part.type) {
              case "group-chainOfThought":
                return <div data-slot="aui_chain-of-thought">{children}</div>;
              case "group-tool":
                if (ToolGroup) {
                  return <ToolGroup group={part}>{children}</ToolGroup>;
                }
                return (
                  <ToolGroupRoot variant="ghost">
                    <ToolGroupTrigger
                      count={part.indices.length}
                      active={part.status.type === "running"}
                    />
                    <ToolGroupContent>{children}</ToolGroupContent>
                  </ToolGroupRoot>
                );
              case "group-reasoning": {
                if (ReasoningGroup) {
                  return (
                    <ReasoningGroup group={part}>{children}</ReasoningGroup>
                  );
                }
                const running = part.status.type === "running";
                return (
                  <ReasoningRoot streaming={running}>
                    <ReasoningTrigger active={running} />
                    <ReasoningContent aria-busy={running}>
                      <ReasoningText>{children}</ReasoningText>
                    </ReasoningContent>
                  </ReasoningRoot>
                );
              }
              case "text":
                return <MarkdownText />;
              case "reasoning":
                return <Reasoning {...part} />;
              case "tool-call":
                return part.toolUI ?? renderToolPart(part, ToolFallbackComponent);
              case "data":
                return part.dataRendererUI;
              case "indicator":
                return (
                  <span
                    data-slot="aui_assistant-message-indicator"
                    className="animate-pulse font-sans"
                    aria-label="Assistant is working"
                  >
                    {"●"}
                  </span>
                );
              case "source": {
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                const p = part as any;
                const href = p.url ? shinySafeUrl(p.url) : null;
                const label = p.title || p.url || "source";
                return (
                  <span className="aui-source-cite bg-muted text-muted-foreground me-1 mb-1 inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs" data-source-url={p.url ?? ""}>
                    {href ? <a href={href} target="_blank" rel="noopener noreferrer" className="text-inherit no-underline">{label}</a> : <span>{label}</span>}
                  </span>
                );
              }
              case "image":
                // eslint-disable-next-line @typescript-eslint/no-explicit-any
                return <img src={(part as any).image} alt="assistant image" className="aui-message-image my-1 max-w-full rounded-lg border" />;
              default:
                return null;
            }
          }}
        </MessagePrimitive.GroupedParts>
        <MessageError />
      </div>

      <div
        data-slot="aui_assistant-message-footer"
        className={cn("ms-2 flex items-center", ACTION_BAR_HEIGHT)}
      >
        <BranchPicker />
        <AssistantActionBar />
        <ShinyTimestamp />
      </div>
    </MessagePrimitive.Root>
  );
};

const AssistantActionBar: FC = () => {
  return (
    <ActionBarPrimitive.Root
      hideWhenRunning
      autohide="not-last"
      className="aui-assistant-action-bar-root text-muted-foreground animate-in fade-in col-start-3 row-start-2 -ms-1 flex gap-1 duration-200"
    >
      <ActionBarPrimitive.Copy asChild>
        <TooltipIconButton tooltip="Copy">
          <AuiIf condition={(s) => s.message.isCopied}>
            <CheckIcon className="animate-in zoom-in-50 fade-in duration-200 ease-out" />
          </AuiIf>
          <AuiIf condition={(s) => !s.message.isCopied}>
            <CopyIcon className="animate-in zoom-in-75 fade-in duration-150" />
          </AuiIf>
        </TooltipIconButton>
      </ActionBarPrimitive.Copy>
      <ActionBarPrimitive.Reload asChild>
        <TooltipIconButton tooltip="Refresh">
          <RefreshCwIcon />
        </TooltipIconButton>
      </ActionBarPrimitive.Reload>
      <ActionBarMorePrimitive.Root>
        <ActionBarMorePrimitive.Trigger asChild>
          <TooltipIconButton
            tooltip="More"
            className="data-[state=open]:bg-accent"
          >
            <MoreHorizontalIcon />
          </TooltipIconButton>
        </ActionBarMorePrimitive.Trigger>
        <ActionBarMorePrimitive.Content
          side="bottom"
          align="start"
          sideOffset={6}
          className="aui-action-bar-more-content bg-popover/95 text-popover-foreground data-[state=open]:fade-in-0 data-[state=open]:zoom-in-95 data-[state=open]:animate-in data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-95 data-[state=closed]:animate-out data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2 z-50 min-w-[8rem] overflow-hidden rounded-xl border p-1.5 shadow-lg backdrop-blur-sm"
        >
          <ActionBarPrimitive.ExportMarkdown asChild>
            <ActionBarMorePrimitive.Item className="aui-action-bar-more-item hover:bg-accent hover:text-accent-foreground focus:bg-accent focus:text-accent-foreground flex cursor-pointer items-center gap-2 rounded-lg px-2.5 py-1.5 text-sm outline-none select-none">
              <DownloadIcon className="size-4" />
              Export as Markdown
            </ActionBarMorePrimitive.Item>
          </ActionBarPrimitive.ExportMarkdown>
        </ActionBarMorePrimitive.Content>
      </ActionBarMorePrimitive.Root>
    </ActionBarPrimitive.Root>
  );
};

const UserMessage: FC = () => {
  return (
    <MessagePrimitive.Root
      data-slot="aui_user-message-root"
      className="fade-in slide-in-from-bottom-1 animate-in grid auto-rows-auto grid-cols-[minmax(72px,1fr)_auto] content-start gap-y-2 px-2 duration-150 [contain-intrinsic-size:auto_200px] [content-visibility:auto] [&:where(>*)]:col-start-2"
      data-role="user"
    >
      <UserMessageAttachments />

      <div className="aui-user-message-content-wrapper relative col-start-2 min-w-0">
        <div className="aui-user-message-content peer bg-muted text-foreground rounded-xl px-4 py-2 wrap-break-word empty:hidden">
          <MessagePrimitive.Parts />
        </div>
        <div className="aui-user-action-bar-wrapper absolute start-0 top-1/2 -translate-x-full -translate-y-1/2 pe-2 peer-empty:hidden rtl:translate-x-full">
          <UserActionBar />
        </div>
        <ShinyTimestamp />
      </div>

      <BranchPicker
        data-slot="aui_user-branch-picker"
        className="col-span-full col-start-1 row-start-3 -me-1 justify-end"
      />
    </MessagePrimitive.Root>
  );
};

const UserActionBar: FC = () => {
  return (
    <ActionBarPrimitive.Root
      hideWhenRunning
      autohide="not-last"
      className="aui-user-action-bar-root flex flex-col items-end"
    >
      <ActionBarPrimitive.Edit asChild>
        <TooltipIconButton tooltip="Edit" className="aui-user-action-edit">
          <PencilIcon />
        </TooltipIconButton>
      </ActionBarPrimitive.Edit>
    </ActionBarPrimitive.Root>
  );
};

const EditComposer: FC = () => {
  return (
    <MessagePrimitive.Root
      data-slot="aui_edit-composer-wrapper"
      className="flex flex-col px-2"
    >
      <ComposerPrimitive.Root className="aui-edit-composer-root border-border/60 dark:border-muted-foreground/15 ms-auto flex w-full max-w-[85%] flex-col rounded-(--composer-radius) border bg-(--composer-bg) shadow-[0_4px_16px_-8px_rgba(0,0,0,0.08),0_1px_2px_rgba(0,0,0,0.04)] dark:shadow-none">
        <ComposerPrimitive.Input
          className="aui-edit-composer-input text-foreground min-h-14 w-full resize-none bg-transparent px-4 pt-3 pb-1 text-base outline-none"
          autoFocus
        />
        <div className="aui-edit-composer-footer mx-2.5 mb-2.5 flex items-center gap-1.5 self-end">
          <ComposerPrimitive.Cancel asChild>
            <Button
              variant="ghost"
              size="sm"
              className="h-8 rounded-full px-3.5"
            >
              Cancel
            </Button>
          </ComposerPrimitive.Cancel>
          <ComposerPrimitive.Send asChild>
            <Button size="sm" className="h-8 rounded-full px-3.5">
              Update
            </Button>
          </ComposerPrimitive.Send>
        </div>
      </ComposerPrimitive.Root>
    </MessagePrimitive.Root>
  );
};

const BranchPicker: FC<BranchPickerPrimitive.Root.Props> = ({
  className,
  ...rest
}) => {
  return (
    <BranchPickerPrimitive.Root
      hideWhenSingleBranch
      className={cn(
        "aui-branch-picker-root text-muted-foreground -ms-2 me-2 inline-flex items-center text-xs",
        className,
      )}
      {...rest}
    >
      <BranchPickerPrimitive.Previous asChild>
        <TooltipIconButton tooltip="Previous">
          <ChevronLeftIcon />
        </TooltipIconButton>
      </BranchPickerPrimitive.Previous>
      <span className="aui-branch-picker-state font-medium">
        <BranchPickerPrimitive.Number /> / <BranchPickerPrimitive.Count />
      </span>
      <BranchPickerPrimitive.Next asChild>
        <TooltipIconButton tooltip="Next">
          <ChevronRightIcon />
        </TooltipIconButton>
      </BranchPickerPrimitive.Next>
    </BranchPickerPrimitive.Root>
  );
};
