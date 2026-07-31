// 官方 per-tool 渲染分发注册表(替代自研 ToolFallback 内部 switch + 已 deprecated 的
// makeAssistantToolUI/useAssistantToolUI)。在 thread 的 tool-call 渲染点按 toolName 分发;
// 未注册的工具回落到 ShinyToolFallback。新增交互/generative-ui/A2UI 工具 = 在此加一项。
import type { ToolCallMessagePartComponent, ToolCallMessagePartProps } from "@assistant-ui/react";
import { AskUserQuestionToolUI } from "./ask-user-question-tool";
import { GenerativePromptToolUI } from "./generative-prompt-tool";

export const TOOL_UI_BY_NAME: Record<string, ToolCallMessagePartComponent> = {
  AskUserQuestion: AskUserQuestionToolUI,
  PromptUser: GenerativePromptToolUI,
};

// 在 thread 的 tool-call 渲染点调用:按 toolName 分发到专属 UI,否则回落到 Fallback。
export function renderToolPart(
  part: ToolCallMessagePartProps,
  Fallback: ToolCallMessagePartComponent,
) {
  const ToolUI = TOOL_UI_BY_NAME[part.toolName];
  return ToolUI ? <ToolUI {...part} /> : <Fallback {...part} />;
}
