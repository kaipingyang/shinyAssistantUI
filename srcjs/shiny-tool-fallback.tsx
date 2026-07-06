import { useState } from "react";
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { Button } from "@/components/ui/button";
import { resolveApprovalHandler } from "./approval-registry";
import { ShinyToolResult } from "./shiny-tool-result";
import { computeToolDepth } from "./helpers";
import {
  SearchIcon, DatabaseIcon, CodeIcon, FileTextIcon, GlobeIcon, TerminalIcon,
  WrenchIcon, FolderIcon, PencilIcon, BookOpenIcon, ZapIcon,
  type LucideIcon,
} from "lucide-react";

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
const _regKey = (inputId: string | undefined, id: string) => `${inputId ?? "_"}::${id}`;

// 组合官方 ToolFallback 的 chrome(Root/Trigger/Content/Args)+ Shiny 富结果 + 审批
// + v0.1.0 观感回归(toolName(参数摘要) 标题 / per-tool 图标 / 子agent嵌套缩进)。
export const ShinyToolFallback: ToolCallMessagePartComponent = (props) => {
  const { toolName, args, argsText, result, status, artifact, toolCallId } = props;
  const ann = artifact as Record<string, unknown> | undefined;
  const pending = result === undefined;
  const needsApproval = ann?.requiresApproval === true;
  const resultType = (ann?.resultType as string | undefined) ?? "auto";
  const resultLang = (ann?.resultLang as string | undefined) ?? "text";
  const isServerTool = ann?.serverTool === true;
  const isError = (status?.type === "incomplete") || ann?.isError === true;
  const [decision, setDecision] = useState<null | "approved" | "denied">(null);

  // ── v0.1.0 标题:toolName(首个参数摘要),如 get_weather(Paris)/Read(/etc/hostname) ──
  const displayTitle = (() => {
    const a = args as Record<string, unknown> | undefined;
    const firstVal = a && typeof a === "object" ? Object.values(a)[0] : undefined;
    if (firstVal != null && typeof firstVal !== "object") {
      const s = String(firstVal).replace(/\s+/g, " ").trim();
      if (s) return `${toolName}(${s.length > 50 ? s.slice(0, 50) + "\u2026" : s})`;
    }
    return toolName;
  })();

  // ── per-tool 图标(opt-in via annotations.icon)──
  const iconName = (ann?.icon as string | undefined)?.toLowerCase();
  const ToolIcon = iconName ? TOOL_ICONS[iconName] : undefined;

  // ── 子agent嵌套缩进 ──
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

  const decide = (approved: boolean) => {
    resolveApprovalHandler(ann?.inputId as string | undefined)?.(toolCallId, approved);
    setDecision(approved ? "approved" : "denied");
  };

  return (
    <div
      className="aui-shiny-tool"
      data-tool-depth={depth}
      style={depth > 0 ? { marginInlineStart: `${Math.min(depth, 4) * 16}px` } : undefined}
    >
      {(isServerTool || ToolIcon) && (
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
        </div>
      )}
      <ToolFallback.Root defaultOpen={ann?.defaultOpen !== undefined ? Boolean(ann.defaultOpen) : true}>
        <ToolFallback.Trigger toolName={displayTitle} status={status} />
        <ToolFallback.Content>
          <ToolFallback.Args argsText={argsText} />

          {pending && needsApproval && decision === null && (
            <div className="aui-shiny-approval flex flex-col gap-2 pt-1">
              {(ann?.title || ann?.description || ann?.displayName) && (
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
              <div className="flex flex-wrap items-center gap-2">
                <Button size="sm" onClick={() => decide(true)}>Approve</Button>
                <Button size="sm" variant="outline" onClick={() => decide(false)}>Deny</Button>
              </div>
            </div>
          )}
          {decision && (
            <div
              data-approval-result={decision}
              className={"aui-shiny-approval-result pt-1 text-xs font-medium " + (decision === "approved" ? "text-green-600" : "text-destructive")}
            >
              {decision === "approved" ? "✓ Approved" : "✕ Denied"}
            </div>
          )}

          {!pending && (
            <div className="aui-shiny-tool-result">
              <p className="text-muted-foreground text-xs font-medium">Result:</p>
              <div className="mt-1">
                <ShinyToolResult result={result} resultType={resultType} resultLang={resultLang} isError={isError} annotations={ann} />
              </div>
            </div>
          )}
        </ToolFallback.Content>
      </ToolFallback.Root>
    </div>
  );
};
