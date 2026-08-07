import type { QuestionSummary } from "./types";

const hasOnlyKeys = (value: Record<string, unknown>, allowed: readonly string[]) =>
  Object.keys(value).every((key) => allowed.includes(key));

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value);

const isAnswer = (value: unknown): value is string | string[] =>
  typeof value === "string" ||
  (Array.isArray(value) && value.every((item) => typeof item === "string"));

// AskUserQuestion运行时schema的唯一入口。严格拒绝未知字段，避免结构化摘要
// 静默吞掉未来SDK字段；pending交互与历史参数视图必须使用同一个结果。
export function parseAskUserQuestionArgs(value: unknown): QuestionSummary[] | null {
  if (!isRecord(value) || !hasOnlyKeys(value, ["questions", "answers"])) return null;
  if (!Array.isArray(value.questions) || value.questions.length === 0) return null;

  const items: QuestionSummary[] = [];
  for (const raw of value.questions) {
    if (!isRecord(raw) || !hasOnlyKeys(raw, ["question", "header", "multiSelect", "options"])) {
      return null;
    }
    if (typeof raw.question !== "string" || !raw.question.trim()) return null;
    if (raw.header !== undefined && typeof raw.header !== "string") return null;
    if (raw.multiSelect !== undefined && typeof raw.multiSelect !== "boolean") return null;
    if (raw.options !== undefined && !Array.isArray(raw.options)) return null;

    const options: QuestionSummary["options"] = [];
    for (const rawOption of (raw.options as unknown[] | undefined) ?? []) {
      if (!isRecord(rawOption) || !hasOnlyKeys(rawOption, ["label", "description"])) return null;
      if (typeof rawOption.label !== "string" || !rawOption.label.trim()) return null;
      if (rawOption.description !== undefined && typeof rawOption.description !== "string") return null;
      options.push({
        label: rawOption.label,
        ...(typeof rawOption.description === "string" ? { description: rawOption.description } : {}),
      });
    }

    items.push({
      question: raw.question,
      ...(typeof raw.header === "string" && raw.header ? { header: raw.header } : {}),
      multiSelect: raw.multiSelect === true,
      options,
    });
  }

  if (value.answers !== undefined) {
    if (!isRecord(value.answers)) return null;
    const itemByQuestion = new Map(items.map((item) => [item.question, item]));
    for (const [question, answer] of Object.entries(value.answers)) {
      const item = itemByQuestion.get(question);
      if (!item || !isAnswer(answer)) return null;
      item.answer = answer;
    }
  }

  return items;
}
