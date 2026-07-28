// AskUserQuestion 交互卡:渲染 Claude Code 的 AskUserQuestion(选项 + 自由文本),
// 收集答案后回传。答案结构(真机逆向锁定):record 键=问题的 `question` 文本,
// 值=单选的 label 字符串 / 多选的 label 数组 / 自由文本字符串。
import { useState } from "react";
import { Button } from "@/components/ui/button";

export type AskOption = { label: string; description?: string };
export type AskQuestion = {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: AskOption[];
};

export function AskQuestionCard({
  questions,
  onSubmit,
  onSkip,
}: {
  questions: AskQuestion[];
  onSubmit: (answers: Record<string, string | string[]>) => void;
  onSkip: () => void;
}) {
  const [submitted, setSubmitted] = useState(false);
  const [sel, setSel] = useState<Record<number, string[]>>({});
  const [custom, setCustom] = useState<Record<number, string>>({});

  const toggle = (qi: number, label: string, multi: boolean) =>
    setSel((s) => {
      const cur = s[qi] ?? [];
      if (multi)
        return { ...s, [qi]: cur.includes(label) ? cur.filter((x) => x !== label) : [...cur, label] };
      return { ...s, [qi]: cur.includes(label) ? [] : [label] };
    });

  const picksFor = (qi: number): string[] => {
    const picks = [...(sel[qi] ?? [])];
    const c = (custom[qi] ?? "").trim();
    if (c) picks.push(c);
    return picks;
  };

  const answeredCount = questions.reduce((n, _q, qi) => n + (picksFor(qi).length ? 1 : 0), 0);

  const submit = () => {
    if (submitted) return;
    const answers: Record<string, string | string[]> = {};
    questions.forEach((q, qi) => {
      const picks = picksFor(qi);
      if (picks.length === 0) return; // 未答的问题略过
      answers[q.question] = q.multiSelect ? picks : picks[0]!;
    });
    setSubmitted(true);
    onSubmit(answers);
  };

  return (
    <div data-slot="ask-user-question" className="aui-ask-question flex flex-col gap-3">
      {questions.map((q, qi) => (
        <div key={qi} data-ask-question={qi} className="flex flex-col gap-1.5">
          {q.header ? (
            <p className="text-muted-foreground text-xs font-semibold">{q.header}</p>
          ) : null}
          <p className="text-sm font-medium">{q.question}</p>
          <div className="flex flex-col gap-1">
            {(q.options ?? []).map((o, oi) => (
              <label
                key={oi}
                data-ask-option={o.label}
                className="aui-ask-option flex cursor-pointer items-start gap-2 text-xs"
              >
                <input
                  type={q.multiSelect ? "checkbox" : "radio"}
                  name={`aui-ask-${qi}`}
                  className="mt-0.5"
                  checked={(sel[qi] ?? []).includes(o.label)}
                  onChange={() => toggle(qi, o.label, !!q.multiSelect)}
                />
                <span>
                  {o.label}
                  {o.description ? (
                    <span className="text-muted-foreground"> — {o.description}</span>
                  ) : null}
                </span>
              </label>
            ))}
            <input
              type="text"
              data-ask-custom={qi}
              placeholder="Other (type a custom answer)…"
              className="mt-1 w-full rounded-md border border-input bg-background px-2 py-1 text-xs"
              value={custom[qi] ?? ""}
              onChange={(e) => setCustom((c) => ({ ...c, [qi]: e.target.value }))}
            />
          </div>
        </div>
      ))}
      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" data-ask-submit disabled={submitted || answeredCount === 0} onClick={submit}>
          Submit answer{questions.length > 1 ? "s" : ""}
        </Button>
        <Button size="sm" variant="ghost" data-ask-skip disabled={submitted} onClick={onSkip}>
          Skip
        </Button>
      </div>
    </div>
  );
}
