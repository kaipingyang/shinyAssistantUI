import type { QuestionKind, QuestionSummary } from "./types";

const hasOnlyKeys = (value: Record<string, unknown>, allowed: readonly string[]) =>
  Object.keys(value).every((key) => allowed.includes(key));

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value);

const isAnswer = (value: unknown): value is string | string[] =>
  typeof value === "string" ||
  (Array.isArray(value) && value.every((item) => typeof item === "string"));

const optionalString = (value: unknown) => value === undefined || typeof value === "string";
const optionalNumber = (value: unknown) =>
  value === undefined || (typeof value === "number" && Number.isFinite(value));

// Mirrors the Claude Code AskUserQuestion input schema (CLI 2.1.327). Unknown keys
// are still rejected so a future field never silently disappears from the card.
const INPUT_KEYS = ["title", "questions", "answers", "annotations", "metadata"] as const;
const QUESTION_KEYS = [
  "question", "header", "kind", "description", "multiSelect", "options",
  "placeholder", "min", "max", "step", "defaultValue", "unit",
] as const;
const OPTION_KEYS = ["label", "description", "preview"] as const;
const KINDS: readonly QuestionKind[] = ["choice", "text", "number"];
const TEXT_ONLY = ["placeholder"] as const;
const NUMBER_ONLY = ["min", "max", "step", "defaultValue", "unit"] as const;

export type AskUserQuestionInput = { title?: string; items: QuestionSummary[] };

function parseQuestion(raw: unknown): QuestionSummary | null {
  if (!isRecord(raw) || !hasOnlyKeys(raw, QUESTION_KEYS)) return null;
  if (typeof raw.question !== "string" || !raw.question.trim()) return null;
  if (!optionalString(raw.header) || !optionalString(raw.description)) return null;
  if (raw.kind !== undefined && !KINDS.includes(raw.kind as QuestionKind)) return null;
  const kind = (raw.kind as QuestionKind | undefined) ?? "choice";
  if (raw.multiSelect !== undefined && typeof raw.multiSelect !== "boolean") return null;
  if (raw.options !== undefined && !Array.isArray(raw.options)) return null;
  if (!optionalString(raw.placeholder) || !optionalString(raw.unit)) return null;
  if (![raw.min, raw.max, raw.step, raw.defaultValue].every(optionalNumber)) return null;

  // Kind-specific fields only apply to their own kind (CLI superRefine).
  if (kind !== "text" && TEXT_ONLY.some((key) => raw[key] !== undefined)) return null;
  if (kind !== "number" && NUMBER_ONLY.some((key) => raw[key] !== undefined)) return null;

  const options: QuestionSummary["options"] = [];
  for (const rawOption of (raw.options as unknown[] | undefined) ?? []) {
    if (!isRecord(rawOption) || !hasOnlyKeys(rawOption, OPTION_KEYS)) return null;
    if (typeof rawOption.label !== "string" || !rawOption.label.trim()) return null;
    if (!optionalString(rawOption.description) || !optionalString(rawOption.preview)) return null;
    options.push({
      label: rawOption.label,
      ...(typeof rawOption.description === "string" ? { description: rawOption.description } : {}),
      ...(typeof rawOption.preview === "string" ? { preview: rawOption.preview } : {}),
    });
  }
  // Inputs without `kind` use the original schema and keep the original, lenient
  // parsing. An explicit `kind` opts into the extended schema and its rules.
  if (raw.kind !== undefined) {
    if (typeof raw.header !== "string") return null;
    if (kind === "choice") {
      if (options.length < 2 || options.length > 4) return null;
    } else if (options.length > 0 || raw.multiSelect !== undefined) {
      return null;
    }
  }

  const summary: QuestionSummary = {
    question: raw.question,
    kind,
    ...(typeof raw.header === "string" && raw.header ? { header: raw.header } : {}),
    ...(typeof raw.description === "string" && raw.description ? { description: raw.description } : {}),
    multiSelect: raw.multiSelect === true,
    options,
  };
  if (kind === "text" && typeof raw.placeholder === "string") summary.placeholder = raw.placeholder;
  if (kind === "number") {
    const { min, max, step, defaultValue } = raw as Record<string, number | undefined>;
    if (min === undefined || max === undefined || !(min < max)) return null;
    if (step !== undefined && !(step > 0)) return null;
    if (defaultValue !== undefined && (defaultValue < min || defaultValue > max)) return null;
    summary.min = min;
    summary.max = max;
    if (step !== undefined) summary.step = step;
    if (defaultValue !== undefined) summary.defaultValue = defaultValue;
    if (typeof raw.unit === "string" && raw.unit) summary.unit = raw.unit;
  }
  return summary;
}

// AskUserQuestion运行时schema的唯一入口。严格拒绝未知字段，避免结构化摘要
// 静默吞掉未来SDK字段；pending交互与历史参数视图必须使用同一个结果。
export function parseAskUserQuestionInput(value: unknown): AskUserQuestionInput | null {
  if (!isRecord(value) || !hasOnlyKeys(value, INPUT_KEYS)) return null;
  if (!optionalString(value.title)) return null;
  if (value.annotations !== undefined && !isRecord(value.annotations)) return null;
  if (value.metadata !== undefined && !isRecord(value.metadata)) return null;
  if (!Array.isArray(value.questions) || value.questions.length === 0 || value.questions.length > 4) {
    return null;
  }

  const items: QuestionSummary[] = [];
  for (const raw of value.questions) {
    const item = parseQuestion(raw);
    if (!item) return null;
    items.push(item);
  }
  // The CLI rejects duplicate question texts and duplicate option labels; answers
  // are keyed by question text, so duplicates would be ambiguous.
  if (new Set(items.map((item) => item.question)).size !== items.length) return null;
  if (items.some((item) => new Set(item.options.map((o) => o.label)).size !== item.options.length)) {
    return null;
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

  return {
    ...(typeof value.title === "string" && value.title.trim() ? { title: value.title } : {}),
    items,
  };
}

export function parseAskUserQuestionArgs(value: unknown): QuestionSummary[] | null {
  return parseAskUserQuestionInput(value)?.items ?? null;
}

// The CLI stores multi-select answers as one comma-joined string (with
// JSON-quoted labels when a label itself contains ", " or a quote).
export function splitMultiSelectAnswer(answer: string | string[]): string[] {
  if (Array.isArray(answer)) return answer;
  const parts: string[] = [];
  let rest = answer;
  while (rest.length) {
    if (rest.startsWith('"')) {
      let end = -1;
      for (let i = 1, escaped = false; i < rest.length; i++) {
        if (escaped) { escaped = false; continue; }
        if (rest[i] === "\\") { escaped = true; continue; }
        if (rest[i] === '"') { end = i; break; }
      }
      if (end < 0) return [answer];
      try {
        const label = JSON.parse(rest.slice(0, end + 1));
        if (typeof label !== "string") return [answer];
        parts.push(label);
      } catch {
        return [answer];
      }
      rest = rest.slice(end + 1);
    } else {
      const at = rest.indexOf(", ");
      parts.push(at < 0 ? rest : rest.slice(0, at));
      rest = at < 0 ? "" : rest.slice(at);
    }
    if (!rest.length) break;
    if (!rest.startsWith(", ")) return [answer];
    rest = rest.slice(2);
  }
  return parts;
}
