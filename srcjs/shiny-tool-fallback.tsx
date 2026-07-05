import { useState } from "react";
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { ToolFallback } from "@/components/assistant-ui/tool-fallback";
import { Button } from "@/components/ui/button";
import { resolveApprovalHandler } from "./approval-registry";

// 官方 ToolFallback + Shiny 侧信道审批(annotations.requiresApproval → approval-registry
// → bridge → R wait_for_approval)。官方原生 approval 走 runtime respondToApproval,而本项目
// 审批是 R promise 侧信道,故在官方卡片下方叠加我们的按钮。
export const ShinyToolFallback: ToolCallMessagePartComponent = (props) => {
  const ann = props.artifact as Record<string, unknown> | undefined;
  const pending = props.result === undefined;
  const needsApproval = ann?.requiresApproval === true;
  const [decision, setDecision] = useState<null | "approved" | "denied">(null);

  const decide = (approved: boolean) => {
    const handler = resolveApprovalHandler(ann?.inputId as string | undefined);
    handler?.(props.toolCallId, approved);
    setDecision(approved ? "approved" : "denied");
  };

  return (
    <div className="aui-shiny-tool">
      <ToolFallback {...props} />
      {pending && needsApproval && decision === null && (
        <div className="aui-shiny-approval flex flex-wrap items-center gap-2 ps-6 pt-1">
          <Button size="sm" onClick={() => decide(true)}>Approve</Button>
          <Button size="sm" variant="outline" onClick={() => decide(false)}>Deny</Button>
        </div>
      )}
      {decision && (
        <div
          className={
            "aui-shiny-approval-result ps-6 pt-1 text-xs font-medium " +
            (decision === "approved" ? "text-green-600" : "text-destructive")
          }
          data-approval-result={decision}
        >
          {decision === "approved" ? "✓ Approved" : "✕ Denied"}
        </div>
      )}
    </div>
  );
};
