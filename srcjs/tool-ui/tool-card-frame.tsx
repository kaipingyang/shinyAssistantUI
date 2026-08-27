// 共享工具卡"外壳":chrome(Root/Trigger/Content)+ 参数视图 + 结果 + 审批门禁 + 子agent
// 缩进 + 决策记忆。ShinyToolFallback(默认审批体)和各 per-tool 交互组件(如 AskUserQuestion)
// 都复用它,交互体经 `approvalBody` 插槽注入 —— 这是官方"per-message inline tool render
// override"模式的落地(替代已 deprecated 的 makeAssistantToolUI/useAssistantToolUI 注册表)。
import { useState, useEffect, useLayoutEffect, useRef, type ReactNode, type UIEvent } from "react";
import { useThreadViewport, type ToolCallMessagePartProps } from "@assistant-ui/react";
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { ShinyToolResult } from "@/shiny-tool-result";
import { computeToolDepth, toolHistoryDefaultOpen, toolCallSummary } from "@/helpers";
import { resolveToolView } from "@/tool-views/resolve";
import { ToolArgsView } from "@/tool-views/ToolArgsView";
import { useShinyConfig } from "@/shiny-config-context";
import { resolveApprovalHandler } from "@/approval-registry";
import {
  SearchIcon, DatabaseIcon, CodeIcon, FileTextIcon, GlobeIcon, TerminalIcon,
  WrenchIcon, FolderIcon, PencilIcon, BookOpenIcon, ZapIcon, ExternalLinkIcon,
  LoaderCircleIcon,
  type LucideIcon,
} from "lucide-react";
import { useOpeningFile } from "@/hooks/use-opening-file";

// annotations.icon(lucide 名)→ 组件,对齐 v0.1.0 的 per-tool 图标。
const TOOL_ICONS: Record<string, LucideIcon> = {
  search: SearchIcon, database: DatabaseIcon, code: CodeIcon, file: FileTextIcon,
  "file-text": FileTextIcon, globe: GlobeIcon, terminal: TerminalIcon, bash: TerminalIcon,
  wrench: WrenchIcon, folder: FolderIcon, pencil: PencilIcon, edit: PencilIcon,
  read: BookOpenIcon, zap: ZapIcon,
};

// 模块级 toolCallId→parentToolCallId 注册表(按 inputId 命名空间隔离多 widget),
// 供 computeToolDepth 计算子agent嵌套缩进(对齐 v0.1.0)。
const _parentRegistry = new Map<string, string | null | undefined>();
export const _regKey = (inputId: string | undefined, id: string) => `${inputId ?? "_"}::${id}`;

// 审批决策注册表：按 inputId::toolCallId 记住 approved/denied，使工具卡在结果到达后
// 重渲染/重挂载时不丢失"✓ Approved"指示。
const _decisionRegistry = new Map<string, "approved" | "denied">();
const _decisionOptsRegistry = new Map<string, ToolDecideOpts>();

const _openRegistry = new Map<string, boolean>();
type ToolScrollState = {
  scrollTop: number;
  scrollLeft: number;
  atBottom: boolean;
  atRight: boolean;
};
const _scrollRegistry = new Map<string, ToolScrollState>();

export function _clearToolCardStateForTests() {
  _parentRegistry.clear();
  _decisionRegistry.clear();
  _decisionOptsRegistry.clear();
  _openRegistry.clear();
  _scrollRegistry.clear();
}

export type ToolDecideOpts = {
  updatedInput?: Record<string, unknown>;
  suggestionIdx?: number;
  suggestionIdxs?: number[];
  customMessage?: string;
  answers?: Record<string, string | string[]>;
};

// 共享工具卡状态 + 审批决策派发(供外壳与各交互体消费)。
export function useToolCard(props: ToolCallMessagePartProps) {
  const { toolName, args, argsText, result, status, timing, artifact, toolCallId } = props;
  const ann = artifact as Record<string, unknown> | undefined;
  const pending = result === undefined;
  const needsApproval = ann?.requiresApproval === true;
  const editLikeTool = toolName === "Edit" || toolName === "MultiEdit" || toolName === "Write";
  const defaultOpen = toolHistoryDefaultOpen(
    ann as { defaultOpen?: boolean } | undefined,
    status?.type === "requires-action" || (pending && needsApproval) || editLikeTool,
  );
  const resultType = (ann?.resultType as string | undefined) ?? "auto";
  const resultLang = (ann?.resultLang as string | undefined) ?? "text";
  const isServerTool = ann?.serverTool === true;
  const isError = (status?.type === "incomplete") || ann?.isError === true;

  const registryKey = _regKey(ann?.inputId as string | undefined, toolCallId);
  const [decision, setDecision] = useState<null | "approved" | "denied">(
    () =>
      _decisionRegistry.get(registryKey) ??
      (ann?.approvalResult as "approved" | "denied" | undefined) ??
      null,
  );
  const [decisionOpts, setDecisionOpts] = useState<ToolDecideOpts | undefined>(
    () => _decisionOptsRegistry.get(registryKey),
  );
  const [open, setOpenState] = useState(() => _openRegistry.get(registryKey) ?? defaultOpen);
  const setOpen = (next: boolean) => {
    _openRegistry.set(registryKey, next);
    setOpenState(next);
  };
  useEffect(() => {
    if (pending && needsApproval && decision === null) setOpen(true);
  }, [pending, needsApproval, decision]);

  const displayTitle = (() => {
    const s = toolCallSummary(toolName, args);
    return s ? `${toolName}(${s})` : toolName;
  })();

  const iconName = (ann?.icon as string | undefined)?.toLowerCase();
  const ToolIcon = iconName ? TOOL_ICONS[iconName] : undefined;

  const inputIdAnno = ann?.inputId as string | undefined;
  const parentToolCallId = ann?.parentToolCallId as string | null | undefined;
  _parentRegistry.set(_regKey(inputIdAnno, toolCallId), parentToolCallId);
  const depth = (() => {
    const scoped = new Map<string, string | null | undefined>();
    const prefix = `${inputIdAnno ?? "_"}::`;
    for (const [k, v] of _parentRegistry) {
      if (k.startsWith(prefix)) scoped.set(k.slice(prefix.length), v);
    }
    return computeToolDepth(toolCallId, scoped);
  })();

  const fileArg = args as { file_path?: unknown; path?: unknown } | undefined;
  const filePath =
    typeof fileArg?.file_path === "string" && fileArg.file_path
      ? fileArg.file_path
      : typeof fileArg?.path === "string" && fileArg.path
        ? fileArg.path
        : undefined;

  const decide = (approved: boolean, opts?: ToolDecideOpts) => {
    resolveApprovalHandler(ann?.inputId as string | undefined)?.(toolCallId, approved, opts);
    _decisionRegistry.set(registryKey, approved ? "approved" : "denied");
    if (opts) _decisionOptsRegistry.set(registryKey, opts);
    else _decisionOptsRegistry.delete(registryKey);
    setDecisionOpts(opts);
    setDecision(approved ? "approved" : "denied");
  };

  const displayArgs = (() => {
    if (!args || typeof args !== "object" || Array.isArray(args)) return args;
    if (decisionOpts?.answers) return { ...args, answers: decisionOpts.answers };
    if (decisionOpts?.updatedInput) return { ...args, ...decisionOpts.updatedInput };
    return args;
  })();

  return {
    toolName, args, displayArgs, argsText, result, status, timing, ann, registryKey,
    pending, needsApproval, decision, decide, depth, open, setOpen,
    displayTitle, resultType, resultLang, isError, isServerTool, filePath, ToolIcon, iconName,
  };
}

export type ToolCard = ReturnType<typeof useToolCard>;

// 工具卡外壳:头部(图标/server badge/文件路径)+ 折叠 chrome(参数 + 结果)+ 审批区
// (pending && needsApproval && 未决策 时显示 meta + 传入的 approvalBody)+ 决策指示。
export function ToolCardFrame({ card, approvalBody }: { card: ToolCard; approvalBody?: ReactNode }) {
  const { onOpenFile } = useShinyConfig();
  const { opening, open: openFile } = useOpeningFile(onOpenFile);
  const {
    toolName, displayArgs, argsText, result, status, timing, ann, registryKey,
    pending, needsApproval, decision, depth, open, setOpen,
    displayTitle, resultType, resultLang, isError, isServerTool, filePath, ToolIcon, iconName,
  } = card;
  const rootRef = useRef<HTMLDivElement>(null);
  const captureScroll = (event: UIEvent<HTMLDivElement>) => {
    const target = event.target as HTMLElement;
    const region = target.dataset.toolScrollRegion;
    if (!region) return;
    const maxTop = Math.max(0, target.scrollHeight - target.clientHeight);
    const maxLeft = Math.max(0, target.scrollWidth - target.clientWidth);
    _scrollRegistry.set(`${registryKey}::${region}`, {
      scrollTop: target.scrollTop,
      scrollLeft: target.scrollLeft,
      atBottom: maxTop > 0 && maxTop - target.scrollTop <= 2,
      atRight: maxLeft > 0 && maxLeft - target.scrollLeft <= 2,
    });
  };
  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    for (const target of root.querySelectorAll<HTMLElement>("[data-tool-scroll-region]")) {
      const region = target.dataset.toolScrollRegion;
      if (!region) continue;
      const saved = _scrollRegistry.get(`${registryKey}::${region}`);
      if (!saved) continue;
      target.scrollTop = saved.atBottom
        ? Math.max(0, target.scrollHeight - target.clientHeight)
        : saved.scrollTop;
      target.scrollLeft = saved.atRight
        ? Math.max(0, target.scrollWidth - target.clientWidth)
        : saved.scrollLeft;
    }
  });

  // 审批卡只在用户原本跟随底部时主动 reveal；如果用户正在上方阅读历史，
  // 不再用无条件 scrollIntoView 把视口劫持回来。审批完成后再次滚到底，
  // 让后续 tool/text stream 重新进入 assistant-ui 的 auto-follow 状态。
  const showApproval = pending && needsApproval && decision === null;
  // ExternalStore marks earlier assistant messages complete when a newer tool
  // message is appended. A tool without a result is still running; preserve
  // requires-action/incomplete, but never present a pending sibling as done.
  const triggerStatus = pending && (!status || status.type === "complete")
    ? ({ type: "running" } as const)
    : status;
  const approvalRef = useRef<HTMLDivElement>(null);
  const viewport = useThreadViewport({ optional: true });
  const isAtBottom = viewport?.isAtBottom ?? false;
  const scrollToBottom = viewport?.scrollToBottom;
  const previousShowApprovalRef = useRef(false);
  const approvalWasFollowingRef = useRef(false);
  useLayoutEffect(() => {
    const justOpened = showApproval && !previousShowApprovalRef.current;
    const justSettled = !showApproval && previousShowApprovalRef.current && decision !== null;
    previousShowApprovalRef.current = showApproval;
    if (justOpened) approvalWasFollowingRef.current = isAtBottom;
    if (!((justOpened && isAtBottom) || (justSettled && approvalWasFollowingRef.current))) return;
    if (!scrollToBottom) return;
    const scroll = scrollToBottom;
    const id = window.setTimeout(() => {
      scroll({ behavior: "smooth" });
    }, 50);
    return () => window.clearTimeout(id);
  }, [showApproval, decision, isAtBottom, scrollToBottom]);

  return (
    <div
      ref={rootRef}
      onScrollCapture={captureScroll}
      className="aui-shiny-tool"
      data-tool-depth={depth}
      style={depth > 0 ? { marginInlineStart: `${Math.min(depth, 4) * 16}px` } : undefined}
    >
      {(isServerTool || ToolIcon || (filePath && onOpenFile)) && (
        <div className="mb-1 flex items-center gap-1.5">
          {ToolIcon && <ToolIcon className="text-muted-foreground size-3.5 shrink-0" data-tool-icon={iconName} />}
          {isServerTool && (
            <span
              data-server-tool
              className="aui-server-tool-badge inline-flex w-fit items-center gap-1 rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
            >
              🌐 server tool
            </span>
          )}
          {filePath && onOpenFile && (
            <button
              type="button"
              data-open-file={filePath}
              aria-busy={opening}
              aria-label={opening ? `Opening ${filePath}` : `Open ${filePath} in RStudio`}
              title={opening ? `Opening ${filePath}…` : `Open ${filePath} in RStudio`}
              onClick={() => openFile(filePath)}
              className="text-muted-foreground hover:text-foreground hover:bg-accent inline-flex w-fit items-center gap-1 rounded px-1 py-0.5 text-[11px] transition-colors"
            >
              {opening ? (
                <><LoaderCircleIcon aria-hidden="true" className="size-3 shrink-0 animate-spin" /><span>Opening…</span></>
              ) : (
                <><ExternalLinkIcon className="size-3 shrink-0" /><span className="aui-tool-file-path break-all text-start">{filePath}</span></>
              )}
            </button>
          )}
        </div>
      )}
      <ToolFallback.Root open={open} onOpenChange={setOpen}>
        <ToolFallback.Trigger toolName={displayTitle} status={triggerStatus} timing={timing} />
        <ToolFallback.Content>
          <ToolArgsView
            view={resolveToolView(toolName, displayArgs, argsText, ann)}
            isRunning={ann?.argsStreaming === true}
          />

          {!pending && (
            <div className="aui-shiny-tool-result">
              <p className="text-muted-foreground text-xs font-medium">Result:</p>
              <div
                data-slot="tool-result-scroll"
                data-tool-scroll-region="result"
                className="mt-1 max-h-96 overflow-auto overscroll-contain"
              >
                <ShinyToolResult result={result} resultType={resultType} resultLang={resultLang} isError={isError} annotations={ann} />
              </div>
            </div>
          )}
        </ToolFallback.Content>
      </ToolFallback.Root>
      {/* 审批 / 交互体放在折叠内容【外面】：待处理时始终可见,即使卡被折叠也能操作。 */}
      {pending && needsApproval && decision === null && (
        <div ref={approvalRef} className="aui-shiny-approval mt-1 flex flex-col gap-2">
          {Boolean(ann?.title || ann?.description || ann?.displayName) && (
            <div className="aui-approval-meta flex flex-col gap-0.5">
              {ann?.title != null && String(ann.title) !== "" && (
                <p data-approval-title className="text-sm font-medium text-foreground">
                  {String(ann.title)}
                </p>
              )}
              {ann?.displayName != null && String(ann.displayName) !== "" && (
                <p data-approval-displayname className="text-xs font-medium text-muted-foreground">
                  {String(ann.displayName)}
                </p>
              )}
              {ann?.description != null && String(ann.description) !== "" && (
                <p data-approval-description className="text-xs text-muted-foreground">
                  {String(ann.description)}
                </p>
              )}
            </div>
          )}
          {approvalBody}
        </div>
      )}
      {decision && (
        <div
          data-approval-result={decision}
          className={"aui-shiny-approval-result mt-1 text-xs font-medium " + (decision === "approved" ? "text-green-600" : "text-destructive")}
        >
          {decision === "approved" ? "✓ Approved" : "✕ Denied"}
        </div>
      )}
    </div>
  );
}
