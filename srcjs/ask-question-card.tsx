// AskUserQuestion 交互卡:渲染 Claude Code 的 AskUserQuestion(选项 + 自由文本),
// 收集答案后回传。答案结构(真机逆向锁定):record 键=问题的 `question` 文本,
// 值=单选的 label 字符串 / 多选的 label 数组 / 自由文本字符串。
// Plan 165: Claude Code 2.1.3xx adds `kind` text / number questions, a form `title`
// and a per-question `description`; their answers are plain strings too.
import { useId, useState } from "react";
import { Button } from "@/components/ui/button";

export type AskOption = { label: string; description?: string; preview?: string };
export type AskQuestion = {
  question: string;
  header?: string;
  kind?: "choice" | "text" | "number";
  description?: string;
  multiSelect?: boolean;
  options?: AskOption[];
  placeholder?: string;
  min?: number;
  max?: number;
  step?: number;
  defaultValue?: number;
  unit?: string;
};

const kindOf = (q: AskQuestion) => q.kind ?? "choice";

// A number answer is valid when it parses and lies within min..max.
const numberProblem = (q: AskQuestion, raw: string): string | null => {
  if (raw.trim() === "") return null;
  const value = Number(raw);
  if (!Number.isFinite(value)) return "Enter a number.";
  if ((q.min !== undefined && value < q.min) || (q.max !== undefined && value > q.max)) {
    return `Enter a value between ${q.min} and ${q.max}.`;
  }
  if (q.step !== undefined) {
    // Same rule as the HTML step attribute: (value - min) is a multiple of step.
    const steps = (value - (q.min ?? 0)) / q.step;
    if (Math.abs(steps - Math.round(steps)) > 1e-9) {
      return `Use steps of ${q.step} from ${q.min ?? 0}.`;
    }
  }
  return null;
};

export function AskQuestionCard({
  title,
  questions,
  onSubmit,
  onSkip,
}: {
  title?: string;
  questions: AskQuestion[];
  onSubmit: (answers: Record<string, string | string[]>) => void;
  onSkip: () => void;
}) {
  const baseId = useId();
  const [submitted, setSubmitted] = useState(false);
  const [sel, setSel] = useState<Record<number, string[]>>({});
  const [custom, setCustom] = useState<Record<number, string>>({});
  const [customActive, setCustomActive] = useState<Record<number, boolean>>({});
  // text / number values, keyed by question index. Numbers start at defaultValue.
  const [values, setValues] = useState<Record<number, string>>(() => {
    const initial: Record<number, string> = {};
    questions.forEach((q, qi) => {
      if (kindOf(q) === "number" && q.defaultValue !== undefined) initial[qi] = String(q.defaultValue);
    });
    return initial;
  });

  const setCustomMode = (qi: number, active: boolean, multi: boolean) => {
    setCustomActive((s) => ({ ...s, [qi]: active }));
    // 单选的 Other 与预设项严格互斥；多选则允许预设 + Other 并存。
    if (active && !multi) setSel((s) => ({ ...s, [qi]: [] }));
  };

  const toggle = (qi: number, label: string, multi: boolean) => {
    if (!multi) setCustomActive((s) => ({ ...s, [qi]: false }));
    setSel((s) => {
      const cur = s[qi] ?? [];
      if (multi)
        return { ...s, [qi]: cur.includes(label) ? cur.filter((x) => x !== label) : [...cur, label] };
      return { ...s, [qi]: cur.includes(label) ? [] : [label] };
    });
  };

  const picksFor = (qi: number): string[] => {
    const q = questions[qi]!;
    if (kindOf(q) !== "choice") {
      const value = (values[qi] ?? "").trim();
      return value ? [value] : [];
    }
    const picks = [...(sel[qi] ?? [])];
    const c = (custom[qi] ?? "").trim();
    if (customActive[qi] && c) picks.push(c);
    return picks;
  };

  const problems = questions.map((q, qi) =>
    kindOf(q) === "number" ? numberProblem(q, values[qi] ?? "") : null);
  const answeredCount = questions.reduce((n, _q, qi) => n + (picksFor(qi).length ? 1 : 0), 0);
  const invalid = problems.some(Boolean);

  const submit = () => {
    if (submitted || invalid) return;
    const answers: Record<string, string | string[]> = {};
    questions.forEach((q, qi) => {
      const picks = picksFor(qi);
      if (picks.length === 0) return; // 未答的问题略过
      if (kindOf(q) === "number") answers[q.question] = String(Number(picks[0]));
      else answers[q.question] = q.multiSelect ? picks : picks[0]!;
    });
    setSubmitted(true);
    onSubmit(answers);
  };

  return (
    <div data-slot="ask-user-question" className="aui-ask-question flex flex-col gap-3">
      {title ? <p data-ask-title className="text-sm font-semibold">{title}</p> : null}
      {questions.map((q, qi) => {
        const kind = kindOf(q);
        const fieldId = `${baseId}-q${qi}`;
        const helpId = q.description ? `${fieldId}-help` : undefined;
        const errorId = problems[qi] ? `${fieldId}-error` : undefined;
        const describedBy = [helpId, errorId].filter(Boolean).join(" ") || undefined;
        const Group = kind === "choice" ? "fieldset" : "div";
        return (
          <Group
            key={qi}
            data-ask-question={qi}
            data-ask-kind={kind}
            aria-describedby={kind === "choice" ? helpId : undefined}
            className="m-0 flex min-w-0 flex-col gap-1.5 border-0 p-0"
          >
            {kind === "choice" ? (
              // The legend must be the fieldset's first child to name the group.
              <legend className="flex flex-col gap-1.5 p-0">
                {q.header ? (
                  <span className="text-muted-foreground text-xs font-semibold">{q.header}</span>
                ) : null}
                <span data-ask-legend className="text-sm font-medium">{q.question}</span>
              </legend>
            ) : (
              <>
                {q.header ? (
                  <p className="text-muted-foreground text-xs font-semibold">{q.header}</p>
                ) : null}
                <label htmlFor={fieldId} className="text-sm font-medium">{q.question}</label>
              </>
            )}
            {q.description ? (
              <p id={helpId} className="text-muted-foreground text-xs">{q.description}</p>
            ) : null}

            {kind === "text" && (
              <textarea
                id={fieldId}
                data-ask-text={qi}
                aria-describedby={helpId}
                rows={2}
                placeholder={q.placeholder}
                disabled={submitted}
                className="w-full resize-y rounded-md border border-input bg-background px-2 py-1 text-xs"
                value={values[qi] ?? ""}
                onChange={(e) => setValues((s) => ({ ...s, [qi]: e.target.value }))}
              />
            )}

            {kind === "number" && (
              <div className="flex flex-col gap-1">
                <div className="flex items-center gap-2">
                  <input
                    id={fieldId}
                    type="number"
                    data-ask-number={qi}
                    aria-describedby={describedBy}
                    aria-invalid={problems[qi] ? true : undefined}
                    min={q.min}
                    max={q.max}
                    step={q.step ?? "any"}
                    disabled={submitted}
                    className="w-32 rounded-md border border-input bg-background px-2 py-1 text-xs"
                    value={values[qi] ?? ""}
                    onChange={(e) => setValues((s) => ({ ...s, [qi]: e.target.value }))}
                  />
                  {q.unit ? <span className="text-muted-foreground text-xs">{q.unit}</span> : null}
                  <span className="text-muted-foreground text-[11px]">{q.min} – {q.max}</span>
                </div>
                {problems[qi] ? (
                  <p id={errorId} role="alert" className="text-destructive text-xs">{problems[qi]}</p>
                ) : null}
              </div>
            )}

            {kind === "choice" && (
              <div className="flex flex-col gap-1">
                {(q.options ?? []).map((o, oi) => (
                  <div key={oi} className="aui-ask-option-group">
                    <label
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
                    {o.preview ? (
                      <pre
                        data-ask-option-preview={o.label}
                        className="bg-muted/50 text-muted-foreground ms-6 mt-1 max-h-40 overflow-auto rounded-md border p-2 text-[11px] leading-4 whitespace-pre-wrap break-words"
                      >
                        {o.preview}
                      </pre>
                    ) : null}
                  </div>
                ))}
                <div
                  data-ask-custom-row={qi}
                  data-custom-active={customActive[qi] ? "true" : "false"}
                  className="aui-ask-custom mt-1 flex items-center gap-2"
                >
                  <input
                    type={q.multiSelect ? "checkbox" : "radio"}
                    name={`aui-ask-${qi}`}
                    data-ask-custom-selector={qi}
                    aria-label={`Use custom answer for ${q.question}`}
                    checked={!!customActive[qi]}
                    onChange={(e) => setCustomMode(qi, e.target.checked, !!q.multiSelect)}
                  />
                  <input
                    type="text"
                    data-ask-custom={qi}
                    aria-label={`Custom answer for ${q.question}`}
                    placeholder="Other (type a custom answer)…"
                    className="w-full rounded-md border border-input bg-background px-2 py-1 text-xs"
                    value={custom[qi] ?? ""}
                    onFocus={() => setCustomMode(qi, true, !!q.multiSelect)}
                    onChange={(e) => {
                      const value = e.target.value;
                      setCustom((c) => ({ ...c, [qi]: value }));
                      if (value.length > 0) setCustomMode(qi, true, !!q.multiSelect);
                    }}
                  />
                </div>
              </div>
            )}
          </Group>
        );
      })}
      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" data-ask-submit disabled={submitted || answeredCount === 0 || invalid} onClick={submit}>
          Submit answer{questions.length > 1 ? "s" : ""}
        </Button>
        <Button size="sm" variant="ghost" data-ask-skip disabled={submitted} onClick={onSkip}>
          Skip
        </Button>
      </div>
    </div>
  );
}
