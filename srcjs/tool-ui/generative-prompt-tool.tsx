// Plan 47 Phase B — per-tool interactive param form (human-in-the-loop).
// A tool named "PromptUser" whose args carry a `fields` spec renders a PromptForm inside the
// shared ToolCardFrame; the user's collected values are returned via the existing approval
// transport as `updatedInput` → R merges into tool_input and approve_tool(updated_input=...).
// Backend emission of this tool (闸门 1b) needs MCP/custom-tool registration in ClaudeAgentSDK;
// the frontend + transport here are ready and fixture-verifiable now.
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { useToolCard, ToolCardFrame } from "./tool-card-frame";
import { PromptForm, type PromptField } from "@/generative/prompt-form";

export const GenerativePromptToolUI: ToolCallMessagePartComponent = (props) => {
  const card = useToolCard(props);
  const args = props.args as { title?: string; fields?: PromptField[] } | undefined;
  const approvalBody = (
    <PromptForm
      title={args?.title}
      fields={args?.fields ?? []}
      onSubmit={(values) => card.decide(true, { updatedInput: values })}
      onSkip={() => card.decide(false, { customMessage: "Skipped" })}
    />
  );
  return <ToolCardFrame card={card} approvalBody={approvalBody} />;
};
