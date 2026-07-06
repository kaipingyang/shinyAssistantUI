import { useState } from "react";
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { Button } from "@/components/ui/button";
import { resolveApprovalHandler } from "./approval-registry";
import { ShinyToolResult } from "./shiny-tool-result";

// 组合官方 ToolFallback 的 chrome(Root/Trigger/Content/Args)+ 我们的富结果渲染
// (resultType: markdown/table/code/image/file/html-sandbox)+ Shiny 侧信道审批
// (annotations.requiresApproval → approval-registry → bridge → R wait_for_approval)。
export const ShinyToolFallback: ToolCallMessagePartComponent = (props) => {
  const { toolName, argsText, result, status, artifact, toolCallId } = props;
  const ann = artifact as Record<string, unknown> | undefined;
  const pending = result === undefined;
  const needsApproval = ann?.requiresApproval === true;
  const resultType = (ann?.resultType as string | undefined) ?? "auto";
  const resultLang = (ann?.resultLang as string | undefined) ?? "text";
  const isServerTool = ann?.serverTool === true;
  const isError = (status?.type === "incomplete") || ann?.isError === true;
  const [decision, setDecision] = useState<null | "approved" | "denied">(null);

  const decide = (approved: boolean) => {
    resolveApprovalHandler(ann?.inputId as string | undefined)?.(toolCallId, approved);
    setDecision(approved ? "approved" : "denied");
  };

  return (
    <div className="aui-shiny-tool">
      {isServerTool && (
        <span
          data-server-tool
          className="aui-server-tool-badge mb-1 inline-flex w-fit items-center gap-1 rounded bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-primary"
        >
          🌐 server tool
        </span>
      )}
      <ToolFallback.Root defaultOpen={ann?.defaultOpen !== undefined ? Boolean(ann.defaultOpen) : true}>
      <ToolFallback.Trigger toolName={toolName} status={status} />
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
