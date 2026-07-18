"use client";
import { safeUrl as shinySafeUrl } from "@/helpers";
import { useShinyConfig } from "@/shiny-config-context";
import { formatMessageTime, detectSlashTrigger, detectMentionTrigger } from "@/helpers";

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
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { PermissionModeControl } from "@/components/assistant-ui/settings-controls";
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
  MicIcon,
  ClockIcon,
  MoreHorizontalIcon,
  PencilIcon,
  RefreshCwIcon,
  SquareIcon,
} from "lucide-react";
import {
  createContext,
  useContext,
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

  return (
    <ThreadPrimitive.Root
      className="aui-root aui-thread-root bg-background @container flex h-full flex-col"
      style={{
        ["--thread-max-width" as string]: "44rem",
        ["--composer-bg" as string]:
          "color-mix(in oklab, var(--color-muted) 30%, var(--color-background))",
        ["--composer-radius" as string]: "1.5rem",
        ["--composer-padding" as string]: "8px",
      }}
    >
      <ThreadPrimitive.Viewport
        turnAnchor="top"
        data-slot="aui_thread-viewport"
        className="relative flex flex-1 flex-col overflow-x-auto overflow-y-scroll scroll-smooth"
      >
        <div
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

const Composer: FC = () => {
  return (
    <ComposerPrimitive.Root className="aui-composer-root relative flex w-full flex-col">
      <ComposerPrimitive.AttachmentDropzone asChild>
        <div
          data-slot="aui_composer-shell"
          className="border-border/60 data-[dragging=true]:border-ring focus-within:border-border dark:border-muted-foreground/15 dark:focus-within:border-muted-foreground/30 flex w-full flex-col gap-2 rounded-(--composer-radius) border bg-(--composer-bg) p-(--composer-padding) shadow-[0_4px_16px_-8px_rgba(0,0,0,0.08),0_1px_2px_rgba(0,0,0,0.04)] transition-[border-color,box-shadow] focus-within:shadow-[0_6px_24px_-8px_rgba(0,0,0,0.12),0_1px_2px_rgba(0,0,0,0.05)] data-[dragging=true]:border-dashed data-[dragging=true]:bg-[color-mix(in_oklab,var(--color-accent)_50%,var(--color-background))] dark:shadow-none"
        >
          <ComposerAttachments />
          <div className="relative">
            <ShinySlashCommands />
            <ShinyMentions />
            <ComposerPrimitive.Input
              placeholder="Send a message..."
              className="aui-composer-input caret-primary placeholder:text-muted-foreground/80 max-h-32 min-h-10 w-full resize-none bg-transparent px-2.5 py-1 text-base outline-none"
              rows={1}
              autoFocus
              enterKeyHint="send"
              aria-label="Message input"
            />
          </div>
          <ComposerAction />
        </div>
      </ComposerPrimitive.AttachmentDropzone>
    </ComposerPrimitive.Root>
  );
};
// Slash 命令面板(Claude Code 风格):合并 config.commands(→ AI 的 prompt/skill)与
// config.action_items(→ 客户端动作,如 /model /clear,不发给 AI)。检测 /trigger 前缀过滤,
// 按 section 分组。选中:prompt 命令插入 `/name `(发送时 expandSlashCommands 展开);
// action 直接 onInvokeAction(执行操作 + 记录气泡,不触发 AI)。↑↓ 选择、Enter/点击确认。
type SlashEntry =
  | { kind: "prompt"; key: string; label: string; desc?: string; section: string }
  | { kind: "action"; key: string; label: string; command: string; desc?: string; section: string;
      item: { id: string; command?: string; label?: string; description?: string; section?: string } };

// ── 每线程冷启动指示器:该线程 client 首次连接(spawn CLI 子进程)期间显示 ──────
// 出现在对话流最后一条消息(用户消息)之后,连上后消失、正常回复接管。
const ShinyWarmingIndicator: FC = () => {
  const { warming } = useShinyConfig();
  if (!warming) return null;
  return (
    <div
      data-slot="aui_warming"
      className="aui-warming-indicator flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm text-muted-foreground"
    >
      <span className="inline-block size-3 shrink-0 animate-spin rounded-full border-2 border-primary border-t-transparent" />
      <span>❄️ Claude Code 正在冷启动这个对话线程…(首次连接较慢,后续会快)</span>
    </div>
  );
};

// ── ClaudeAgentSDK 能力对齐 UI ────────────────────────────────────────────────
// #3 限流 banner + #2 子agent/Task 进度卡 + #4 系统状态行 + #7 stop_task 按钮
const ShinyStatusPanels: FC = () => {
  const { rateLimit, tasks, statusText, stopTask } = useShinyConfig();
  const activeTasks = (tasks ?? []).filter(
    (t) => !/^(completed|done|stopped|failed|cancelled|canceled|errored)$/i.test(t.status ?? ""),
  );
  const hasAny = rateLimit || activeTasks.length > 0 || statusText;
  if (!hasAny) return null;
  return (
    <div className="aui-sdk-panels flex flex-col gap-2">
      {rateLimit && (
        <div className="aui-rate-limit-banner flex items-center gap-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-800 dark:border-amber-700 dark:bg-amber-950/40 dark:text-amber-200"
             data-slot="aui_rate_limit">
          <span>⚠️ Rate limited{rateLimit.type ? ` (${rateLimit.type})` : ""}</span>
          {typeof rateLimit.utilization === "number" && <span>· {Math.round(rateLimit.utilization)}% used</span>}
          {rateLimit.resetsAt && <span>· resets {rateLimit.resetsAt}</span>}
        </div>
      )}
      {activeTasks.map((t) => (
        <div key={t.taskId}
             data-slot="aui_task_card" data-task-id={t.taskId}
             className="aui-task-card flex items-center gap-2 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm">
          <span className="animate-pulse">⚙️</span>
          <span className="flex-1 truncate">
            {t.description || t.summary || `Subagent ${t.taskId.slice(0, 6)}`}
            {t.toolName ? <span className="text-muted-foreground"> · {t.toolName}</span> : null}
            {t.status ? <span className="text-muted-foreground"> · {t.status}</span> : null}
          </span>
          {stopTask && (
            <button
              type="button"
              data-slot="aui_task_stop" data-stop-task={t.taskId}
              onClick={() => stopTask(t.taskId)}
              className="rounded px-2 py-0.5 text-xs text-destructive hover:bg-destructive/10"
            >Stop</button>
          )}
        </div>
      ))}
      {statusText && (
        <div className="aui-status-line flex items-center gap-2 px-1 text-xs text-muted-foreground"
             data-slot="aui_status_line">
          <span className="inline-block h-2 w-2 animate-pulse rounded-full bg-primary" />
          <span>{statusText}</span>
        </div>
      )}
    </div>
  );
};

// #1 成本/用量页脚
const ShinyUsageFooter: FC = () => {
  const { usage } = useShinyConfig();
  if (!usage || (usage.costUsd == null && usage.tokens == null)) return null;
  const parts: string[] = [];
  if (usage.costUsd != null) parts.push(`$${usage.costUsd.toFixed(4)}`);
  if (usage.tokens != null) parts.push(`${usage.tokens.toLocaleString()} tokens`);
  if (usage.turns != null) parts.push(`${usage.turns} turn${usage.turns === 1 ? "" : "s"}`);
  if (usage.durationMs != null) parts.push(`${(usage.durationMs / 1000).toFixed(1)}s`);
  return (
    <div className="aui-usage-footer flex items-center justify-end gap-2 px-1 text-xs text-muted-foreground"
         data-slot="aui_usage_footer" data-cost-usd={usage.costUsd ?? ""}>
      <span>{parts.join(" · ")}</span>
    </div>
  );
};

const ShinySlashCommands: FC = () => {
  const { commands, actionItems, onInvokeAction } = useShinyConfig();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const aui = useAui() as any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const text = useAuiState((s: any) => (s.composer?.text as string) ?? "");
  const [idx, setIdx] = useState(0);

  const total = commands.length + actionItems.length;
  const cursor = text.length;
  const trig = total ? detectSlashTrigger(text, cursor) : null;
  if (!trig) return null;
  const q = trig.query.toLowerCase();

  const entries: SlashEntry[] = [
    ...actionItems
      .filter((a) => (a.command ?? a.id).toLowerCase().startsWith(q) || a.id.toLowerCase().startsWith(q) || (a.label ?? "").toLowerCase().includes(q))
      .map((a): SlashEntry => ({ kind: "action", key: `a-${a.id}`, label: a.label ?? a.id, command: a.command ?? a.id, desc: a.description, section: a.section ?? "Actions", item: a })),
    ...commands
      .filter((c) => c.name.toLowerCase().startsWith(q))
      .map((c): SlashEntry => ({ kind: "prompt", key: `c-${c.name}`, label: c.name, desc: c.description, section: c.category ?? "Commands" })),
  ];
  if (entries.length === 0) return null;
  const sel = Math.min(idx, entries.length - 1);

  const chooseCommand = (name: string) => {
    const before = text.slice(0, trig.offset);
    const after = text.slice(cursor);
    aui.composer().setText(`${before}/${name} ${after}`);
    setIdx(0);
    (document.querySelector(".aui-composer-input") as HTMLTextAreaElement | null)?.focus();
  };
  const chooseAction = (item: { id: string; command?: string; label?: string; description?: string; section?: string }) => {
    // 清掉输入框里的 /trigger,再执行动作(不发给 AI)
    const before = text.slice(0, trig.offset);
    const after = text.slice(cursor);
    aui.composer().setText(`${before}${after}`);
    setIdx(0);
    onInvokeAction(item);
  };
  const pick = (e: SlashEntry) => (e.kind === "action" ? chooseAction(e.item) : chooseCommand(e.label));

  // 按 section 分组(保持插入顺序)
  const sections: { name: string; items: { e: SlashEntry; gi: number }[] }[] = [];
  entries.forEach((e, gi) => {
    let s = sections.find((x) => x.name === e.section);
    if (!s) { s = { name: e.section, items: [] }; sections.push(s); }
    s.items.push({ e, gi });
  });

  return (
    <div
      className="aui-slash-popover bg-popover text-popover-foreground absolute bottom-full left-0 z-50 mb-1 max-h-72 w-80 overflow-auto rounded-lg border p-1 shadow-lg"
      onKeyDownCapture={(ev) => {
        if (ev.key === "ArrowDown") { ev.preventDefault(); setIdx((i) => (i + 1) % entries.length); }
        else if (ev.key === "ArrowUp") { ev.preventDefault(); setIdx((i) => (i - 1 + entries.length) % entries.length); }
        else if (ev.key === "Enter") { ev.preventDefault(); pick(entries[sel]); }
        else if (ev.key === "Escape") { ev.preventDefault(); setIdx(0); }
      }}
    >
      {sections.map((s) => (
        <div key={s.name}>
          <div className="text-muted-foreground px-2.5 pt-1.5 pb-0.5 text-[10px] font-semibold uppercase tracking-wide">{s.name}</div>
          {s.items.map(({ e, gi }) => (
            <button
              key={e.key}
              type="button"
              data-slash-cmd={e.kind === "prompt" ? e.label : undefined}
              data-slash-action={e.kind === "action" ? e.item.id : undefined}
              onMouseDown={(ev) => { ev.preventDefault(); pick(e); }}
              className={
                "aui-slash-item flex w-full flex-col items-start gap-0.5 rounded-md px-2.5 py-1.5 text-start text-sm " +
                (gi === sel ? "bg-accent text-accent-foreground" : "hover:bg-accent/60")
              }
            >
              <span className="font-medium">{e.kind === "action" ? `⚙️ /${e.command}` : `/${e.label}`}</span>
              {e.kind === "action" && e.label !== e.command && <span className="text-muted-foreground text-xs">{e.label}</span>}
              {e.desc && <span className="text-muted-foreground text-xs">{e.desc}</span>}
            </button>
          ))}
        </div>
      ))}
    </div>
  );
};

// @mention 工具发现弹窗:检测 @trigger,按名过滤 config.tools,插入 `@name `。
const ShinyMentions: FC = () => {
  const { tools } = useShinyConfig();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const aui = useAui() as any;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const text = useAuiState((s: any) => (s.composer?.text as string) ?? "");
  const [idx, setIdx] = useState(0);

  const cursor = text.length;
  const trig = tools.length ? detectMentionTrigger(text, cursor) : null;
  if (!trig) return null;
  const q = trig.query.toLowerCase();
  const matches = tools.filter((t) => t.name.toLowerCase().startsWith(q));
  if (matches.length === 0) return null;
  const sel = Math.min(idx, matches.length - 1);

  const choose = (name: string) => {
    const before = text.slice(0, trig.offset);
    const after = text.slice(cursor);
    aui.composer().setText(`${before}@${name} ${after}`);
    setIdx(0);
    const ta = document.querySelector(".aui-composer-input") as HTMLTextAreaElement | null;
    ta?.focus();
  };

  return (
    <div
      className="aui-mention-popover bg-popover text-popover-foreground absolute bottom-full left-0 z-50 mb-1 max-h-60 w-72 overflow-auto rounded-lg border p-1 shadow-lg"
      onKeyDownCapture={(e) => {
        if (e.key === "ArrowDown") { e.preventDefault(); setIdx((i) => (i + 1) % matches.length); }
        else if (e.key === "ArrowUp") { e.preventDefault(); setIdx((i) => (i - 1 + matches.length) % matches.length); }
      }}
    >
      {matches.map((t, i) => (
        <button
          key={t.name}
          type="button"
          data-mention-tool={t.name}
          onMouseDown={(e) => { e.preventDefault(); choose(t.name); }}
          className={
            "aui-mention-item flex w-full flex-col items-start gap-0.5 rounded-md px-2.5 py-1.5 text-start text-sm " +
            (i === sel ? "bg-accent text-accent-foreground" : "hover:bg-accent/60")
          }
        >
          <span className="font-medium">@{t.name}</span>
          {t.description && <span className="text-muted-foreground text-xs">{t.description}</span>}
        </button>
      ))}
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
        const t = (aui.composer().getState().text as string) ?? "";
        if (t.trim()) {
          onEnqueue(t);
          aui.composer().setText("");
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

const ComposerAction: FC = () => {
  return (
    <div className="aui-composer-action-wrapper relative flex items-center justify-between">
      <div className="flex min-w-0 items-center gap-1.5">
        <ComposerAddAttachment />
        <PermissionModeControl compact />
      </div>
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
  const ACTION_BAR_HEIGHT = `-mb-7.5 min-h-7.5 ${ACTION_BAR_PT}`;

  return (
    <MessagePrimitive.Root
      data-slot="aui_assistant-message-root"
      data-role="assistant"
      className="fade-in slide-in-from-bottom-1 animate-in relative duration-150"
    >
      <div
        data-slot="aui_assistant-message-content"
        // [contain-intrinsic-size:auto_24px] fixes issue #4104, don't change without checking for regressions
        className="text-foreground px-2 leading-relaxed wrap-break-word [contain-intrinsic-size:auto_24px] [content-visibility:auto]"
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
                return part.toolUI ?? <ToolFallbackComponent {...part} />;
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
      className="fade-in slide-in-from-bottom-1 animate-in grid auto-rows-auto grid-cols-[minmax(72px,1fr)_auto] content-start gap-y-2 px-2 duration-150 [contain-intrinsic-size:auto_60px] [content-visibility:auto] [&:where(>*)]:col-start-2"
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
