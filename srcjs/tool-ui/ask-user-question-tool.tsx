// AskUserQuestion 的 per-tool 交互组件(官方 generative-ui 落地的第一个迁移项)。
// 复用共享 ToolCardFrame 外壳 + useToolCard 审批派发;交互体 = AskQuestionCard。
// 答案经现有审批传输回传(approve_tool(updated_input=answers)),transport 不变。
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { useToolCard, ToolCardFrame } from "./tool-card-frame";
import { AskQuestionCard, type AskQuestion } from "@/ask-question-card";

export const AskUserQuestionToolUI: ToolCallMessagePartComponent = (props) => {
  const card = useToolCard(props);
  const questions = ((props.args as { questions?: AskQuestion[] } | undefined)?.questions) ?? [];
  const approvalBody = (
    <AskQuestionCard
      questions={questions}
      onSubmit={(answers) => card.decide(true, { answers })}
      onSkip={() => card.decide(false, { customMessage: "Skipped" })}
    />
  );
  return <ToolCardFrame card={card} approvalBody={approvalBody} />;
};
