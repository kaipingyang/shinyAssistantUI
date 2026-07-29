// ShinyToolFallback:默认工具卡(未在 registry 注册专属 UI 的所有工具)。
// 复用共享 ToolCardFrame 外壳,交互体 = 权限审批(Approve / Always-allow 多选 / Deny / Deny+消息)。
// per-tool 交互(如 AskUserQuestion)已拆到 tool-ui/registry,不再走此处。
import { useState } from "react";
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { Button } from "@/components/ui/button";
import { useToolCard, ToolCardFrame } from "./tool-ui/tool-card-frame";

// CLI permission_suggestion → 人性化的 "Always allow …" 按钮标签。
type PermSuggestion = {
  type?: string;
  mode?: string;
  directories?: string[];
  rules?: Array<{ toolName?: string; tool_name?: string; ruleContent?: string; rule_content?: string }>;
};
function suggestionLabel(sug: PermSuggestion): string {
  switch (sug?.type) {
    case "setMode": {
      const m = String(sug.mode ?? "");
      if (m === "acceptEdits") return "Always allow edits";
      if (m === "bypassPermissions") return "Always allow all";
      if (m === "plan") return "Switch to plan mode";
      return m ? `Mode: ${m}` : "Always allow";
    }
    case "addDirectories": {
      const d = sug.directories?.[0] ?? "";
      const base = d.replace(/\/+$/, "").split("/").pop() || d;
      return base ? `Always allow folder ${base}` : "Always allow folder";
    }
    case "addRules": {
      const r = sug.rules?.[0];
      const tool = String(r?.toolName ?? r?.tool_name ?? "");
      const content = r?.ruleContent ?? r?.rule_content;
      if (!tool) return "Always allow";
      return content ? `Always allow ${tool}(${content})` : `Always allow ${tool}`;
    }
    default:
      return "Always allow";
  }
}

export const ShinyToolFallback: ToolCallMessagePartComponent = (props) => {
  const card = useToolCard(props);
  const { decide } = card;
  const suggestions = (card.ann?.suggestions as PermSuggestion[] | undefined) ?? [];
  const [denyOpen, setDenyOpen] = useState(false);
  const [denyText, setDenyText] = useState("");
  const [alwaysOpen, setAlwaysOpen] = useState(false);
  const [checkedIdxs, setCheckedIdxs] = useState<number[]>([]);
  const toggleChecked = (i: number) =>
    setCheckedIdxs((c) => (c.includes(i) ? c.filter((x) => x !== i) : [...c, i]));

  const approvalBody = denyOpen ? (
    <div className="aui-approval-deny flex flex-col gap-2">
      <textarea
        data-approval-deny-input
        className="aui-approval-deny-input min-h-[3.5rem] w-full resize-y rounded-md border border-input bg-background px-2 py-1 text-sm"
        rows={2}
        autoFocus
        placeholder="Tell Claude what to do differently (optional)"
        value={denyText}
        onChange={(e) => setDenyText(e.target.value)}
      />
      <div className="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          variant="outline"
          data-approval-deny-send
          onClick={() => decide(false, { customMessage: denyText.trim() || undefined })}
        >
          Send &amp; deny
        </Button>
        <Button size="sm" variant="ghost" onClick={() => setDenyOpen(false)}>
          Back
        </Button>
      </div>
    </div>
  ) : alwaysOpen ? (
    <div className="aui-approval-always flex flex-col gap-2" data-approval-always-panel>
      <p className="text-muted-foreground text-xs">
        Select rule(s) to remember, then approve:
      </p>
      {suggestions.map((sug, i) => (
        <label
          key={i}
          data-always-option={i}
          className="aui-always-option flex cursor-pointer items-start gap-2 text-xs"
        >
          <input
            type="checkbox"
            data-always-check={i}
            className="mt-0.5"
            checked={checkedIdxs.includes(i)}
            onChange={() => toggleChecked(i)}
          />
          <span>{suggestionLabel(sug)}</span>
        </label>
      ))}
      <div className="flex flex-wrap items-center gap-2">
        <Button
          size="sm"
          data-approval-always-apply
          disabled={checkedIdxs.length === 0}
          onClick={() => decide(true, { suggestionIdxs: checkedIdxs })}
        >
          Approve &amp; remember{checkedIdxs.length ? ` (${checkedIdxs.length})` : ""}
        </Button>
        <Button
          size="sm"
          variant="ghost"
          onClick={() => { setAlwaysOpen(false); setCheckedIdxs([]); }}
        >
          Back
        </Button>
      </div>
    </div>
  ) : (
    <div className="flex flex-wrap items-center gap-2">
      <Button size="sm" onClick={() => decide(true)}>Approve</Button>
      {suggestions.length > 0 && (
        <Button
          size="sm"
          variant="secondary"
          data-approval-always-toggle
          onClick={() => setAlwaysOpen(true)}
        >
          Always allow&#8230; &#9662;
        </Button>
      )}
      <Button size="sm" variant="outline" onClick={() => decide(false)}>Deny</Button>
      <Button
        size="sm"
        variant="ghost"
        data-approval-deny-with-msg
        onClick={() => setDenyOpen(true)}
      >
        Deny &amp; tell Claude&#8230;
      </Button>
    </div>
  );

  return <ToolCardFrame card={card} approvalBody={approvalBody} />;
};
