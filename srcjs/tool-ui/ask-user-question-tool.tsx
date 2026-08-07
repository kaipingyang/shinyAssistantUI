// AskUserQuestion 的 per-tool 交互组件(官方 generative-ui 落地的第一个迁移项)。
// 复用共享 ToolCardFrame 外壳 + useToolCard 审批派发;交互体 = AskQuestionCard。
// 答案经现有审批传输回传(approve_tool(updated_input=answers)),transport 不变。
import type { ToolCallMessagePartComponent } from "@assistant-ui/react";
import { useToolCard, ToolCardFrame } from "./tool-card-frame";
import { AskQuestionCard } from "@/ask-question-card";
import { Button } from "@/components/ui/button";
import { parseAskUserQuestionArgs } from "@/tool-views/ask-user-question-args";

export const AskUserQuestionToolUI: ToolCallMessagePartComponent = (props) => {
  const card = useToolCard(props);
  const questions = parseAskUserQuestionArgs(props.args);
  const approvalBody = questions ? (
    <AskQuestionCard
      questions={questions}
      onSubmit={(answers) => card.decide(true, { answers })}
      onSkip={() => card.decide(false, { customMessage: "Skipped" })}
    />
  ) : (
    <div
      data-ask-questions-invalid
      role="alert"
      className="border-destructive/30 bg-destructive/5 flex flex-col gap-2 rounded-md border p-3"
    >
      <p className="text-destructive text-sm">
        Unable to display these questions. Review the raw arguments above or skip this request.
      </p>
      <Button
        type="button"
        variant="outline"
        onClick={() => card.decide(false, { customMessage: "Skipped invalid AskUserQuestion payload" })}
      >
        Skip
      </Button>
    </div>
  );
  return <ToolCardFrame card={card} approvalBody={approvalBody} />;
};
