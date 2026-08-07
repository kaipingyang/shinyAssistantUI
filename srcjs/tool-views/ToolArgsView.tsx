// Dumb 渲染:按 ToolView.kind 复用现有渲染件(DiffViewer / SyntaxHighlighter /
// JsonHighlighter),不含任何工具判定逻辑(那在 resolve.ts)。data-arg-view / data-arg-lang
// 供无头断言。
import type { FC } from "react";
import type { ToolView } from "./types";
import { DiffViewer } from "@/components/assistant-ui/diff-viewer";
import {
  SyntaxHighlighter,
  JsonHighlighter,
} from "@/components/assistant-ui/syntax-highlighter";

export const ToolArgsView: FC<{ view: ToolView }> = ({ view }) => {
  if (view.kind === "diff") {
    return (
      <div
        data-arg-view="diff"
        data-slot="aui_edit_diff"
        className="mt-1 max-h-96 overflow-y-auto"
      >
        <DiffViewer
          oldFile={{ content: view.oldContent, name: view.fileName }}
          newFile={{ content: view.newContent, name: view.fileName }}
          viewMode="unified"
          startLine={view.startLine}
        />
      </div>
    );
  }

  if (view.kind === "code") {
    return (
      <div
        data-arg-view="code"
        data-arg-lang={view.lang}
        data-slot="tool-fallback-args"
        className="aui-tool-fallback-args bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs"
      >
        <SyntaxHighlighter language={view.lang} code={view.code} />
      </div>
    );
  }

  if (view.kind === "questions") {
    return (
      <div
        data-arg-view="questions"
        data-slot="tool-fallback-args"
        className="aui-tool-questions bg-muted/50 mt-1 flex flex-col gap-2 rounded-md p-2.5 text-xs"
      >
        {view.items.map((q, i) => (
          <div
            key={i}
            data-question-kind={q.multiSelect ? "multiple" : "single"}
            className="flex flex-col gap-1"
          >
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="text-muted-foreground font-semibold">
                {q.header || `Question ${i + 1}`}
              </span>
              <span className="bg-background text-muted-foreground rounded-full border px-1.5 py-0.5 text-[10px]">
                {q.multiSelect ? "Multiple choice" : "Single choice"}
              </span>
            </div>
            <p className="text-foreground font-medium">{q.question}</p>
            {q.options.length > 0 && (
              <ul className="flex flex-col gap-0.5 ps-1">
                {q.options.map((option, oi) => (
                  <li
                    key={oi}
                    data-question-option={option.label}
                    className="flex items-start gap-1.5"
                  >
                    <span aria-hidden className="text-muted-foreground">
                      {q.multiSelect ? "\u2610" : "\u25CB"}
                    </span>
                    <span className="text-foreground/90">{option.label}</span>
                    {option.description && (
                      <span className="text-muted-foreground">{option.description}</span>
                    )}
                  </li>
                ))}
              </ul>
            )}
            {q.answer !== undefined && (
              <div data-question-answer className="bg-background/70 mt-0.5 flex gap-1.5 rounded px-2 py-1">
                <span className="text-muted-foreground font-medium">Answer:</span>
                <span className="text-foreground">
                  {Array.isArray(q.answer) ? q.answer.join(", ") : q.answer}
                </span>
              </div>
            )}
          </div>
        ))}
      </div>
    );
  }

  if (view.kind === "todos") {
    return (
      <ul
        data-arg-view="todos"
        className="aui-tool-todos bg-muted/50 mt-1 flex flex-col gap-1 rounded-md p-2.5 text-xs"
      >
        {view.items.map((t, i) => {
          const done = t.status === "completed";
          const active = t.status === "in_progress";
          return (
            <li
              key={i}
              data-todo-status={t.status}
              className="aui-tool-todo flex items-start gap-2"
            >
              <span
                aria-hidden
                className={
                  done
                    ? "text-green-600"
                    : active
                      ? "text-blue-600"
                      : "text-muted-foreground"
                }
              >
                {done ? "\u2713" : active ? "\u25D0" : "\u25CB"}
              </span>
              <span className={done ? "text-muted-foreground line-through" : ""}>
                {(active && t.activeForm) || t.content}
              </span>
            </li>
          );
        })}
      </ul>
    );
  }

  if (view.kind === "query") {
    return (
      <div
        data-arg-view="query"
        className="aui-tool-query bg-muted/50 mt-1 flex flex-col gap-1 rounded-md p-2.5 text-xs"
      >
        {view.fields.map((f, i) => {
          const link = !!f.href && /^https?:\/\//i.test(f.href);
          return (
            <div key={i} data-query-field={f.label} className="flex gap-2">
              <span className="text-muted-foreground min-w-[4rem] shrink-0 font-medium">
                {f.label}
              </span>
              {link ? (
                <a
                  href={f.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="break-all text-blue-700 underline dark:text-blue-300"
                >
                  {f.value}
                </a>
              ) : (
                <span className="text-foreground/90 font-mono break-all">
                  {f.value}
                </span>
              )}
            </div>
          );
        })}
      </div>
    );
  }

  // json 兜底:保留原 ShinyToolArgs 的 raw/json 双态。
  if (view.raw) {
    return (
      <div
        data-arg-view="json"
        data-slot="tool-fallback-args"
        data-args-format="raw"
        className="aui-tool-fallback-args"
      >
        <pre className="aui-tool-fallback-args-value bg-muted/50 text-foreground/90 rounded-md p-2.5 text-xs whitespace-pre-wrap">
          {view.text}
        </pre>
      </div>
    );
  }
  return (
    <div
      data-arg-view="json"
      data-slot="tool-fallback-args"
      data-args-format="json"
      className="aui-tool-fallback-args bg-muted/50 overflow-x-auto rounded-md p-2.5 text-xs"
    >
      <JsonHighlighter code={view.text} />
    </div>
  );
};
