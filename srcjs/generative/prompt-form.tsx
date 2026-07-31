"use client";

// Plan 47 Phase B — generic parameter form for human-in-the-loop tool calls.
// Driven by a `fields` spec (from a tool's args); collects {name: value} and submits once.
// Zero new deps (hand-rolled, like AskQuestionCard). The collected object is sent back via the
// tool card's decide() → R approve_tool(updated_input=...) (see generative-prompt-tool.tsx).
import { useState } from "react";
import { Button } from "@/components/ui/button";

export type PromptFieldType = "radio" | "select" | "slider" | "text" | "checkbox";
export type PromptField = {
  name: string;
  type: PromptFieldType;
  label?: string;
  options?: string[];
  min?: number;
  max?: number;
  step?: number;
  default?: string | number | boolean;
};

function initialValue(f: PromptField): string | number | boolean {
  if (f.default !== undefined) return f.default;
  switch (f.type) {
    case "checkbox": return false;
    case "slider": return f.min ?? 0;
    case "radio":
    case "select": return f.options?.[0] ?? "";
    default: return "";
  }
}

export function PromptForm({
  fields,
  title,
  onSubmit,
  onSkip,
}: {
  fields: PromptField[];
  title?: string;
  onSubmit: (values: Record<string, string | number | boolean>) => void;
  onSkip: () => void;
}) {
  const [submitted, setSubmitted] = useState(false);
  const [values, setValues] = useState<Record<string, string | number | boolean>>(() => {
    const v: Record<string, string | number | boolean> = {};
    for (const f of fields) v[f.name] = initialValue(f);
    return v;
  });
  const set = (name: string, val: string | number | boolean) =>
    setValues((s) => ({ ...s, [name]: val }));

  const submit = () => {
    if (submitted) return;
    setSubmitted(true);
    onSubmit(values);
  };

  return (
    <div data-slot="prompt-form" className="aui-prompt-form flex flex-col gap-3">
      {title ? <p className="text-sm font-medium">{title}</p> : null}
      {fields.map((f) => (
        <div key={f.name} data-prompt-field={f.name} className="flex flex-col gap-1">
          {f.label ? <label className="text-xs font-medium">{f.label}</label> : null}

          {f.type === "radio" && (
            <div className="flex flex-col gap-1">
              {(f.options ?? []).map((o) => (
                <label key={o} className="flex cursor-pointer items-center gap-2 text-xs">
                  <input
                    type="radio"
                    name={`aui-pf-${f.name}`}
                    checked={values[f.name] === o}
                    onChange={() => set(f.name, o)}
                  />
                  <span>{o}</span>
                </label>
              ))}
            </div>
          )}

          {f.type === "select" && (
            <select
              data-field={f.name}
              className="border-input bg-background rounded-md border px-2 py-1 text-xs"
              value={String(values[f.name] ?? "")}
              onChange={(e) => set(f.name, e.target.value)}
            >
              {(f.options ?? []).map((o) => (
                <option key={o} value={o}>{o}</option>
              ))}
            </select>
          )}

          {f.type === "slider" && (
            <div className="flex items-center gap-2">
              <input
                data-field={f.name}
                type="range"
                min={f.min ?? 0}
                max={f.max ?? 100}
                step={f.step ?? 1}
                value={Number(values[f.name] ?? 0)}
                onChange={(e) => set(f.name, Number(e.target.value))}
                className="flex-1"
              />
              <span className="text-muted-foreground w-12 text-end text-xs tabular-nums">
                {String(values[f.name] ?? "")}
              </span>
            </div>
          )}

          {f.type === "text" && (
            <input
              data-field={f.name}
              type="text"
              className="border-input bg-background rounded-md border px-2 py-1 text-xs"
              value={String(values[f.name] ?? "")}
              onChange={(e) => set(f.name, e.target.value)}
            />
          )}

          {f.type === "checkbox" && (
            <label className="flex cursor-pointer items-center gap-2 text-xs">
              <input
                data-field={f.name}
                type="checkbox"
                checked={Boolean(values[f.name])}
                onChange={(e) => set(f.name, e.target.checked)}
              />
              <span>{f.label ?? f.name}</span>
            </label>
          )}
        </div>
      ))}

      <div className="flex flex-wrap items-center gap-2">
        <Button size="sm" data-prompt-submit disabled={submitted} onClick={submit}>
          Submit
        </Button>
        <Button size="sm" variant="ghost" data-prompt-skip disabled={submitted} onClick={onSkip}>
          Skip
        </Button>
      </div>
    </div>
  );
}
